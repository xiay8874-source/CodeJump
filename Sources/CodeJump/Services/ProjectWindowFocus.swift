import AppKit
@preconcurrency import ApplicationServices
import CodeJumpCore
import Darwin
import Foundation
import OSLog

/// Called only for an explicit project selection, from a detached task.
/// Unknown or ambiguous windows fall back to the editor's project CLI.
enum ProjectWindowFocus {
    private static let maximumWindows = 24
    private static let maximumNodesPerWindow = 80
    private static let maximumDepth = 6

    static func focus(project: ProjectRoot, editor: EditorKind,
                      configuredProjects: [ProjectRoot], applicationPath: String? = nil) async -> Bool {
        let trace = Diagnostic()
        guard editor == .idea else { trace.event("unsupported_editor"); return false }
        guard AXIsProcessTrusted() else { trace.event("permission_missing"); return false }
        guard !Task.isCancelled else { trace.event("cancelled_at_start"); return false }
        let canonicalRoot = canonicalDirectory(project.path)
        guard canonicalRoot == project.path else {
            trace.event("invalid_root", code: canonicalRoot == nil ? 0 : 1); return false
        }
        let applications: [ApplicationProbe] = await MainActor.run {
            NSWorkspace.shared.runningApplications.compactMap { application in
                if let applicationPath {
                    guard application.bundleURL?.resolvingSymlinksInPath().path == URL(fileURLWithPath: applicationPath).resolvingSymlinksInPath().path else { return nil }
                }
                let identifier = application.bundleIdentifier ?? ""
                guard identifier.hasPrefix("com.jetbrains.intellij")
                        || (application.localizedName?.hasPrefix("IntelliJ IDEA") ?? false) else { return nil }
                return ApplicationProbe(pid: application.processIdentifier,
                    bundleMatches: identifier == "com.jetbrains.intellij" || identifier.hasPrefix("com.jetbrains.intellij."),
                    executableMatches: application.executableURL?.lastPathComponent == "idea",
                    terminated: application.isTerminated)
            }
        }
        for application in applications {
            // Bits: 1=bundle match, 2=executable match, 4=terminated. No app paths are logged.
            trace.event("app_probe", code: (application.bundleMatches ? 1 : 0)
                | (application.executableMatches ? 2 : 0) | (application.terminated ? 4 : 0), pid: application.pid)
        }
        let pids = applications.filter { $0.bundleMatches && $0.executableMatches && !$0.terminated }.map(\.pid)
        guard !pids.isEmpty, pids.count <= 4, !Task.isCancelled else {
            trace.event("app_filter_failed", count: pids.count, limit: 4); return false
        }

        let budget = Budget(trace: trace)
        var windows: [Window] = []
        for pid in pids {
            trace.event("enumerate_windows", pid: pid)
            let application = AXUIElementCreateApplication(pid)
            guard let elements = elements(application, kAXWindowsAttribute as CFString,
                                          limit: maximumWindows - windows.count, budget: budget) else {
                trace.event("windows_failed", pid: pid, count: windows.count); return false
            }
            trace.event("windows_found", pid: pid, count: elements.count)
            for element in elements {
                guard budget.available else { trace.event("budget_before_window", count: windows.count); return false }
                let title = string(element, kAXTitleAttribute as CFString, budget: budget) ?? ""
                guard let metadata = projectMetadata(element, budget: budget) else {
                    trace.event("metadata_failed", pid: pid, count: windows.count); return false
                }
                // Root code: 0=no authority, 1=matches, 2=other root, 3=unreadable root.
                let rootCode: Int32 = !metadata.hasAuthoritativePath ? 0
                    : metadata.root == project.path ? 1 : metadata.root == nil ? 3 : 2
                trace.event("window_inspected", code: rootCode, pid: pid, count: windows.count,
                    limit: projectNames(project).contains(where: { titleMatches(title, name: $0) }) ? 1 : 0)
                windows.append(Window(pid: pid, element: element, title: title, metadata: metadata))
            }
        }
        guard budget.available, !windows.isEmpty else { trace.event("scan_empty_or_expired", count: windows.count); return false }

        let exact = windows.indices.filter { windows[$0].metadata.root == project.path }
        let selected: Int
        if exact.count == 1 {
            selected = exact[0]
            trace.event("selected_exact_root", count: selected)
        } else if !exact.isEmpty {
            trace.event("ambiguous_exact_roots", count: exact.count)
            return false
        } else {
            // A title can identify a project only if both our imported roots and
            // every running IDEA window make that name unambiguous.
            let names = projectNames(project)
            var matches = Set<Int>()
            for name in names {
                let roots = Set(configuredProjects.filter { projectNames($0).contains(name) }.map(\.path))
                guard roots == Set([project.path]) else { trace.event("ambiguous_imported_name", count: roots.count); continue }
                let matchingWindows = windows.indices.filter { titleMatches(windows[$0].title, name: name) }
                guard matchingWindows.count == 1, let index = matchingWindows.first,
                      !windows[index].metadata.hasAuthoritativePath else {
                    trace.event("name_window_rejected", count: matchingWindows.count); continue
                }
                matches.insert(index)
            }
            guard matches.count == 1, let index = matches.first else { trace.event("no_unique_match", count: matches.count); return false }
            selected = index
            trace.event("selected_unique_name", count: selected)
        }

        let window = windows[selected]
        // Validate the user's imported root again after the asynchronous scan.
        guard !Task.isCancelled, canonicalDirectory(project.path) == project.path else {
            trace.event("selection_cancelled_or_root_changed"); return false
        }
        let pid = window.pid
        let activated = await MainActor.run {
            NSRunningApplication(processIdentifier: pid)?.activate(options: []) ?? false
        }
        guard activated, !Task.isCancelled else { trace.event("activation_failed_or_cancelled", pid: pid); return false }
        // Raise after activation so a previously key window cannot reclaim focus.
        AXUIElementSetMessagingTimeout(window.element, 0.06)
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        trace.event(raised == .success ? "focused" : "raise_failed", code: raised.rawValue, pid: pid)
        return raised == .success
    }

    private struct ApplicationProbe: Sendable {
        let pid: pid_t
        let bundleMatches: Bool
        let executableMatches: Bool
        let terminated: Bool
    }

    /// Immutable request-scoped context: concurrent requests never share mutable diagnostics.
    private struct Diagnostic: Sendable {
        private static let logger = Logger(subsystem: "com.xiay8874.CodeJump", category: "project_focus")
        let identifier = String(UUID().uuidString.prefix(8))
        let started = ProcessInfo.processInfo.systemUptime

        func event(_ stage: String, code: Int32 = 0, pid: pid_t = 0,
                   count: Int = 0, limit: Int = 0, depth: Int = 0, attribute: String = "",
                   reportedCount: Int = -1, arrayCount: Int = -1) {
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            Self.logger.info("request=\(identifier, privacy: .public) stage=\(stage, privacy: .public) code=\(code) pid=\(pid) count=\(count) limit=\(limit) depth=\(depth) attribute=\(attribute, privacy: .public) reported_count=\(reportedCount) array_count=\(arrayCount) elapsed_ms=\(milliseconds)")
        }
    }

    private struct Window {
        let pid: pid_t
        let element: AXUIElement
        let title: String
        let metadata: Metadata
    }
    private struct Metadata {
        var root: String?
        var hasAuthoritativePath = false
    }
    private struct Budget {
        let deadline = ProcessInfo.processInfo.systemUptime + 1.2
        let trace: Diagnostic
        var available: Bool { !Task.isCancelled && ProcessInfo.processInfo.systemUptime < deadline }
        func prepare(_ element: AXUIElement) -> Bool {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard !Task.isCancelled, remaining > 0 else { return false }
            AXUIElementSetMessagingTimeout(element, Float(min(0.06, remaining)))
            return true
        }
    }

    /// Inspect shallow window chrome only. Text values, editor contents, file
    /// trees, lists, menus and scroll areas are never requested or descended into.
    private static func projectMetadata(_ window: AXUIElement, budget: Budget) -> Metadata? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var position = 0
        var visited = 0
        var buttons = 0
        var deepest = 0
        let excluded: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText", "AXOutline", "AXTable",
                                     "AXList", "AXScrollArea", "AXMenuBar", "AXMenu", "AXMenuItem", "AXWebArea"]
        while position < queue.count {
            guard budget.available, visited < maximumNodesPerWindow else {
                budget.trace.event("metadata_budget_or_nodes", count: visited, limit: queue.count, depth: deepest); return nil
            }
            let (element, depth) = queue[position]
            position += 1; visited += 1
            deepest = max(deepest, depth)
            let role = string(element, kAXRoleAttribute as CFString, budget: budget) ?? ""
            if excluded.contains(role) { continue }
            if ["AXButton", "AXPopUpButton", "AXMenuButton"].contains(role) {
                buttons += 1
                let description = string(element, kAXDescriptionAttribute as CFString, budget: budget) ?? ""
                let title = string(element, kAXTitleAttribute as CFString, budget: budget) ?? ""
                // IDEA's project selector is observed as Description "项目: NAME，菜单"
                // (or "Project: NAME, menu") with Help equal to the project root.
                // An unrelated toolbar button or the document title is not authority.
                if isProjectSelector(description) || isProjectSelector(title),
                   let help = string(element, kAXHelpAttribute as CFString, budget: budget) {
                    budget.trace.event("project_selector", count: visited, limit: buttons, depth: depth)
                    let path = help.trimmingCharacters(in: .whitespacesAndNewlines)
                    if path.hasPrefix("/") || path.hasPrefix("~/") {
                        let root = canonicalDirectory(path)
                        budget.trace.event("selector_root", code: root == nil ? 0 : 1,
                                           count: visited, depth: depth)
                        return Metadata(root: root, hasAuthoritativePath: true)
                    }
                    budget.trace.event("selector_help_not_path", count: visited, depth: depth)
                }
            }
            guard depth < maximumDepth else { continue }
            guard let children = elements(element, kAXChildrenAttribute as CFString,
                                          limit: maximumNodesPerWindow - queue.count, budget: budget,
                                          unsupportedIsEmpty: true) else {
                budget.trace.event("children_branch_failed", count: visited, limit: queue.count, depth: depth)
                return nil
            }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }
        budget.trace.event("metadata_no_selector", count: visited, limit: buttons, depth: deepest)
        return budget.available ? Metadata() : nil
    }

    private static func isProjectSelector(_ label: String) -> Bool {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["项目:", "项目：", "project:", "project："].contains { value.hasPrefix($0) }
    }

    private static func projectNames(_ project: ProjectRoot) -> Set<String> {
        Set([project.name, URL(fileURLWithPath: project.path).lastPathComponent].filter { !$0.isEmpty })
    }

    private static func titleMatches(_ title: String, name: String) -> Bool {
        // Do not extract a project from document paths in an IDEA window title.
        // Example: "demo-alpha – ~/.../demo-beta/Foo.java" still belongs to demo-alpha.
        title == name || [" – ", " — ", " - "].contains { title.hasPrefix(name + $0) }
    }

    private static func canonicalDirectory(_ path: String) -> String? {
        guard !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { return nil }
        let expanded: String
        if path.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path + String(path.dropFirst())
        } else {
            guard path.hasPrefix("/") else { return nil }
            expanded = path
        }
        guard let pointer = expanded.withCString({ realpath($0, nil) }) else { return nil }
        defer { free(pointer) }
        let canonical = String(cString: pointer)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: canonical, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return canonical
    }

    private static func string(_ element: AXUIElement, _ attribute: CFString, budget: Budget) -> String? {
        guard budget.prepare(element) else { budget.trace.event("string_budget", attribute: attribute as String); return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            if result != .attributeUnsupported && result != .noValue {
                budget.trace.event("string_ax_error", code: result.rawValue, attribute: attribute as String)
            }
            return nil
        }
        guard let text = value as? String, text.utf8.prefix(4097).count <= 4096 else { return nil }
        return text
    }

    private static func elements(_ element: AXUIElement, _ attribute: CFString, limit: Int,
                                 budget: Budget, unsupportedIsEmpty: Bool = false) -> [AXUIElement]? {
        // Java's lazy AX bridge can report zero windows through the count API
        // while the array getter exposes the live windows. Use one direct IPC.
        if (attribute as String) == "AXWindows" {
            return copyElementArray(element, attribute, limit: limit, budget: budget,
                                    unsupportedIsEmpty: unsupportedIsEmpty, reportedCount: nil)
        }
        guard budget.prepare(element) else { budget.trace.event("elements_budget", attribute: attribute as String); return nil }
        var count: CFIndex = 0
        let result = AXUIElementGetAttributeValueCount(element, attribute, &count)
        budget.trace.event("elements_count_result", code: result.rawValue, count: count,
                           limit: limit, attribute: attribute as String)
        if result == .attributeUnsupported || result == .notImplemented || result == .failure
            || (result == .success && count == 0) {
            // Java accessibility bridges can expose an AX array while omitting
            // the separate count API. Read only its element handles, never text.
            budget.trace.event("elements_count_fallback", code: result.rawValue, limit: limit, attribute: attribute as String)
            return copyElementArray(element, attribute, limit: limit, budget: budget,
                                    unsupportedIsEmpty: unsupportedIsEmpty,
                                    reportedCount: result == .success ? count : nil)
        }
        if unsupportedIsEmpty, result == .noValue { return [] }
        guard result == .success, count >= 0, count <= limit else {
            budget.trace.event(result == .success ? "elements_limit" : "elements_count_failed",
                               code: result.rawValue, count: count, limit: limit, attribute: attribute as String); return nil
        }
        guard budget.prepare(element) else { budget.trace.event("elements_copy_budget", attribute: attribute as String); return nil }
        var values: CFArray?
        let copyResult = AXUIElementCopyAttributeValues(element, attribute, 0, count, &values)
        guard copyResult == .success, let values else {
            budget.trace.event("elements_copy_failed", code: copyResult.rawValue, count: count, attribute: attribute as String); return nil
        }
        let actualCount = CFArrayGetCount(values)
        budget.trace.event("elements_values_count", count: actualCount, limit: limit,
                           attribute: attribute as String, reportedCount: count, arrayCount: actualCount)
        guard actualCount <= limit else { return nil }
        return (values as [AnyObject]).compactMap { value in
            CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! AXUIElement) : nil
        }
    }

    private static func copyElementArray(_ element: AXUIElement, _ attribute: CFString, limit: Int,
                                         budget: Budget, unsupportedIsEmpty: Bool,
                                         reportedCount: Int?) -> [AXUIElement]? {
        guard budget.prepare(element) else { budget.trace.event("elements_array_budget", attribute: attribute as String); return nil }
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        if unsupportedIsEmpty, result == .attributeUnsupported || result == .noValue {
            budget.trace.event("elements_array_empty", code: result.rawValue, attribute: attribute as String,
                               reportedCount: reportedCount ?? -1, arrayCount: 0)
            return []
        }
        guard result == .success, let value, CFGetTypeID(value) == CFArrayGetTypeID() else {
            budget.trace.event("elements_array_failed", code: result.rawValue, attribute: attribute as String,
                               reportedCount: reportedCount ?? -1); return nil
        }
        let array = value as! CFArray
        let actualCount = CFArrayGetCount(array)
        budget.trace.event("elements_array_count", count: actualCount, limit: limit,
                           attribute: attribute as String, reportedCount: reportedCount ?? -1, arrayCount: actualCount)
        guard actualCount <= limit else {
            budget.trace.event("elements_limit", count: actualCount, limit: limit, attribute: attribute as String); return nil
        }
        return (array as [AnyObject]).compactMap { child in
            CFGetTypeID(child) == AXUIElementGetTypeID() ? (child as! AXUIElement) : nil
        }
    }
}
