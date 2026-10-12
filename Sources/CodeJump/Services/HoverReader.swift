@preconcurrency import ApplicationServices
import AppKit
import Foundation
import OSLog
import CodeJumpCore

struct CaptureFragment: Sendable {
    let text: String
    let origin: String
    let precise: Bool
    var labels: [String] = []
    var utf16Offset: Int? = nil
}

struct HoverCapture: Sendable {
    let fragments: [CaptureFragment]
    let application: String
    let elapsedMilliseconds: Double
    var hasRecognizableReference: Bool {
        fragments.contains {
            !ReferenceSelection.select(text: $0.text, utf16Offset: $0.utf16Offset).isEmpty
            || ($0.precise && ReferenceParser.parseExplicitLabel($0.text) != nil)
        }
    }
}

enum HoverReader {
    static var isTrusted: Bool { AXIsProcessTrusted() }
    private static let manualAccessibility = ManualAccessibilityRegistry()
    private static let diagnostics = Logger(subsystem: "com.xiay8874.CodeJump", category: "capture_diagnostics")
    /// Opt-in local troubleshooting: defaults write com.xiay8874.CodeJump diagnosticCapture -bool true
    private static var diagnosticsEnabled: Bool { UserDefaults.standard.bool(forKey: "diagnosticCapture") }

    @MainActor static func requestPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Read only after an explicit hotkey. No timer, mouse monitor, or screen recording.
    static func capture(x: Double, y: Double, application: String, pid: pid_t? = nil) -> HoverCapture {
        let started = Date()
        let diagnose = diagnosticsEnabled
        var notes: [String] = []
        // Electron apps (Codex, ChatGPT, Obsidian, VS Code…) build their web accessibility tree only
        // after a client opts in. Ask once per process; the first build needs a brief moment.
        if let pid {
            let outcome = manualAccessibility.enable(pid: pid)
            notes.append("ax_opt_in=\(outcome.summary)")
            if outcome.newlyEnabled { Thread.sleep(forTimeInterval: 0.3) }
        }
        // Text markers exist only in web content. Native and Java UIs (IDEA) answer each failed AX query
        // slowly, so they skip the marker walks.
        let webContent = pid.map { manualAccessibility.isWebContent(pid: $0) } ?? false
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        var hit: AXUIElement?
        let hitResult = AXUIElementCopyElementAtPosition(system, Float(x), Float(y), &hit)
        guard hitResult == .success, let hit else {
            if diagnose { diagnostics.notice("app=\(application, privacy: .public) \(notes.joined(separator: " "), privacy: .public) hit_failed=\(hitResult.rawValue)") }
            return HoverCapture(fragments: [], application: application, elapsedMilliseconds: Date().timeIntervalSince(started) * 1000)
        }
        AXUIElementSetMessagingTimeout(hit, 0.15)
        if diagnose {
            var chain: [String] = []
            var node: AXUIElement? = hit
            for _ in 0..<6 {
                guard let element = node else { break }
                let role = string(element, kAXRoleAttribute as CFString) ?? "?"
                let children = (attribute(element, kAXChildrenAttribute as CFString) as? [AnyObject])?.count ?? -1
                chain.append("\(role)(\(children))")
                node = attribute(element, kAXParentAttribute as CFString).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
            }
            notes.append("chain=" + chain.joined(separator: ">"))
        }
        var fragments: [CaptureFragment] = []
        var current: AXUIElement? = hit
        for depth in 0..<4 {
            guard let element = current, Date().timeIntervalSince(started) < 0.7 else { break }
            let role = string(element, kAXRoleAttribute as CFString) ?? ""
            // Selected text has a deliberate user boundary; do not synthesize copy keystrokes.
            if let selected = string(element, kAXSelectedTextAttribute as CFString), !selected.isEmpty {
                fragments.append(CaptureFragment(text: String(selected.prefix(4096)), origin: "选中文字", precise: true))
            }
            if let url = attribute(element, kAXURLAttribute as CFString) {
                let value: String?
                if CFGetTypeID(url) == CFURLGetTypeID() { value = (url as! URL).absoluteString }
                else { value = url as? String }
                if let value, !value.isEmpty {
                    // Only this link's own label (or the hit descendant inside it) may
                    // supplement its target. Another reference in the paragraph is unrelated.
                    let labelElements = depth == 0 ? [element] : [element, hit]
                    let labels = labelElements.flatMap { labelElement in
                        [kAXTitleAttribute, kAXValueAttribute].compactMap { name in
                            string(labelElement, name as CFString).flatMap { $0.count <= 512 ? $0 : nil }
                        }
                    }
                    fragments.append(CaptureFragment(text: String(value.prefix(4096)), origin: "引用链接", precise: depth <= 2, labels: labels))
                }
            }
            if depth == 0, let nearby = textAtPosition(element, point: CGPoint(x: x, y: y))
                ?? (webContent ? markerTextAtPosition(element, point: CGPoint(x: x, y: y),
                                                      deadline: started.addingTimeInterval(0.6), note: &notes) : nil) {
                fragments.append(CaptureFragment(text: nearby.text, origin: "鼠标字符位置", precise: true, utf16Offset: nearby.offset))
            }
            for name in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                guard let value = string(element, name as CFString), !value.isEmpty, value.utf16.count <= 4096 else { continue }
                let precise = depth == 0 && [kAXButtonRole, "AXLink", kAXStaticTextRole].contains(role) && value.count < 300
                fragments.append(CaptureFragment(text: value, origin: depth == 0 ? "鼠标指向文字" : "邻近上下文", precise: precise))
            }
            let parent = attribute(element, kAXParentAttribute as CFString)
            current = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        if webContent, !fragments.contains(where: { $0.origin == "选中文字" }),
           let selection = markerSelection(from: hit, point: CGPoint(x: x, y: y), deadline: started.addingTimeInterval(0.9), note: &notes) {
            fragments.append(selection)
        }
        var seen = Set<String>()
        fragments = fragments.filter { seen.insert("\($0.origin):\($0.text)").inserted }
        fragments = fragments.enumerated().sorted {
            func rank(_ fragment: CaptureFragment) -> Int {
                if fragment.origin == "选中文字" { return 0 }
                if fragment.origin == "引用链接" { return 1 }
                if fragment.utf16Offset != nil { return 2 }
                return fragment.precise ? 3 : 4
            }
            let left = rank($0.element), right = rank($1.element)
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
        if diagnose {
            let summary = fragments.map { "[\($0.origin)|\($0.precise ? "P" : "-")|\($0.text.count)|\(String($0.text.prefix(40)).replacingOccurrences(of: "\n", with: "⏎"))]" }
            diagnostics.notice("app=\(application, privacy: .public) \(notes.joined(separator: " "), privacy: .public) fragments=\(fragments.count) \(summary.joined(separator: " "), privacy: .public)")
        }
        return HoverCapture(fragments: fragments, application: application,
            elapsedMilliseconds: Date().timeIntervalSince(started) * 1000)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &result) == .success else { return nil }
        return result
    }

    private static func string(_ element: AXUIElement, _ name: CFString) -> String? {
        attribute(element, name) as? String
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &result) == .success else { return nil }
        return result
    }

    /// Chromium/Electron apps (Codex, ChatGPT, Obsidian reading view) and WebKit report a selection in
    /// non-editable page text as text markers on the page, never as AXSelectedText on the hovered node.
    /// The selection is used only while the pointer is over its on-screen bounds, so an old selection
    /// elsewhere on the page cannot replace what the user points at. Unknown bounds make it a
    /// confirmation-only fallback.
    private static func markerSelection(from hit: AXUIElement, point: CGPoint, deadline: Date, note: inout [String]) -> CaptureFragment? {
        var current: AXUIElement? = hit
        for level in 0..<32 {
            guard let element = current, Date() < deadline else { note.append("marker=none@\(level)"); return nil }
            AXUIElementSetMessagingTimeout(element, 0.15)
            if let range = attribute(element, "AXSelectedTextMarkerRange" as CFString) {
                guard let text = parameterized(element, "AXStringForTextMarkerRange", range) as? String else { note.append("marker=no_string@\(level)"); return nil }
                let selected = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !selected.isEmpty, selected.utf16.count <= 4096 else { note.append("marker=empty@\(level)"); return nil }
                var bounds = CGRect.null
                if let value = parameterized(element, "AXBoundsForTextMarkerRange", range),
                   CFGetTypeID(value) == AXValueGetTypeID(), AXValueGetValue(value as! AXValue, .cgRect, &bounds) {
                    guard !bounds.isEmpty, bounds.insetBy(dx: -6, dy: -6).contains(point) else {
                        note.append("marker=outside@\(level) bounds=\(Int(bounds.minX)),\(Int(bounds.minY)),\(Int(bounds.width))x\(Int(bounds.height)) point=\(Int(point.x)),\(Int(point.y))"); return nil
                    }
                    note.append("marker=hit@\(level)")
                    return CaptureFragment(text: selected, origin: "选中文字", precise: true)
                }
                note.append("marker=no_bounds@\(level)")
                return CaptureFragment(text: selected, origin: "选中文字", precise: false)
            }
            let parent = attribute(element, kAXParentAttribute as CFString)
            current = parent.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        }
        note.append("marker=depth_limit")
        return nil
    }

    /// Chromium/WebKit pages answer AXRangeForPosition only inside text fields, and a long static text
    /// (a log line followed by its JSON request) exceeds the plain-value bound. Text markers locate the
    /// pointer inside the hovered element's own text; a bounded window around it is returned.
    private static func markerTextAtPosition(_ element: AXUIElement, point: CGPoint, deadline: Date,
                                             note: inout [String]) -> (text: String, offset: Int)? {
        guard let rangeValue = parameterized(element, "AXTextMarkerRangeForUIElement", element),
              CFGetTypeID(rangeValue) == AXTextMarkerRangeGetTypeID() else {
            note.append("pointer_marker=no_element_range"); return nil
        }
        let elementRange = rangeValue as! AXTextMarkerRange
        let start = AXTextMarkerRangeCopyStartMarker(elementRange)
        let end = AXTextMarkerRangeCopyEndMarker(elementRange)
        guard let full = parameterized(element, "AXStringForTextMarkerRange", elementRange) as? String,
              !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            note.append("pointer_marker=no_text"); return nil
        }
        let text = full as NSString
        func length(from first: AXTextMarker, to last: AXTextMarker) -> Int? {
            (parameterized(element, "AXStringForTextMarkerRange", AXTextMarkerRangeCreate(nil, first, last)) as? String)?.utf16.count
        }
        var offset: Int?
        var method = "none"
        // 1. Direct hit test, asked of the element first and then of its ancestors up to the page root.
        var position = point
        if let value = AXValueCreate(.cgPoint, &position) {
            var current: AXUIElement? = element
            for level in 0..<4 {
                guard let node = current, Date() < deadline else { break }
                if let marker = parameterized(node, "AXTextMarkerForPosition", value),
                   CFGetTypeID(marker) == AXTextMarkerGetTypeID(),
                   let prefix = length(from: start, to: marker as! AXTextMarker), prefix > 0, prefix < text.length {
                    offset = prefix; method = "position@\(level)"; break
                }
                current = attribute(node, kAXParentAttribute as CFString).flatMap {
                    CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil
                }
            }
        }
        // 2. Walk the element word by word and compare each word's on-screen bounds with the pointer.
        if offset == nil {
            var current = start
            var steps = 0
            while steps < 800, Date() < deadline {
                steps += 1
                guard let nextValue = parameterized(element, "AXNextWordEndTextMarkerForTextMarker", current),
                      CFGetTypeID(nextValue) == AXTextMarkerGetTypeID() else { method = "words_unsupported"; break }
                let next = nextValue as! AXTextMarker
                if CFEqual(next, current) { method = "words_end"; break }
                var bounds = CGRect.null
                if let boundsValue = parameterized(element, "AXBoundsForTextMarkerRange", AXTextMarkerRangeCreate(nil, current, next)),
                   CFGetTypeID(boundsValue) == AXValueGetTypeID(), AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds),
                   !bounds.isEmpty, bounds.insetBy(dx: -1, dy: -2).contains(point),
                   let through = length(from: start, to: next), through > 0 {
                    offset = min(through, text.length) - 1; method = "words@\(steps)"; break
                }
                if CFEqual(next, end) { method = "words_miss@\(steps)"; break }
                current = next
            }
        }
        guard let offset else { note.append("pointer_marker=\(method) len=\(text.length)"); return nil }
        let lower = max(0, offset - 512), upper = min(text.length, offset + 512)
        guard upper > lower else { return nil }
        note.append("pointer_marker=\(method) offset=\(offset)/\(text.length)")
        return (text.substring(with: NSRange(location: lower, length: upper - lower)), offset - lower)
    }

    private static func textAtPosition(_ element: AXUIElement, point: CGPoint) -> (text: String, offset: Int)? {
        var point = point
        guard let parameter = AXValueCreate(.cgPoint, &point) else { return nil }
        var output: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXRangeForPositionParameterizedAttribute as CFString,
              parameter, &output) == .success, let output, CFGetTypeID(output) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(output as! AXValue, .cfRange, &range), range.location >= 0 else { return nil }
        // Ask for a bounded window around the pointer, never the full document.
        let total = (attribute(element, kAXNumberOfCharactersAttribute as CFString) as? NSNumber)?.intValue
        let pointerOffset = range.location
        let start = max(0, range.location - 512)
        let end = min(range.location + 512, total ?? (range.location + max(1, range.length)))
        guard end > start else { return nil }
        range = CFRange(location: start, length: end - start)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var text: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
              rangeValue, &text) == .success else { return nil }
        guard let text = text as? String else { return nil }
        return (text, pointerOffset - start)
    }
}

/// Remembers processes already asked to expose their Electron accessibility tree.
private final class ManualAccessibilityRegistry: @unchecked Sendable {
    struct Outcome {
        let newlyEnabled: Bool
        let summary: String
    }
    private let lock = NSLock()
    private var requested = Set<pid_t>()
    private var webContent: [pid_t: Bool] = [:]

    /// Chromium shells and WebKit browsers expose page text through text markers.
    func isWebContent(pid: pid_t) -> Bool {
        lock.lock()
        if let known = webContent[pid] { lock.unlock(); return known }
        lock.unlock()
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        let value = Self.isChromiumBased(pid: pid) || bundleID.hasPrefix("com.apple.Safari")
        lock.lock()
        if webContent.count > 256 { webContent.removeAll() }
        webContent[pid] = value
        lock.unlock()
        return value
    }

    /// Chromium-based apps (Electron, Codex's owl runtime, Chrome-family browsers) expose web text only
    /// after an assistive client opts in. Electron honors AXManualAccessibility; other Chromium shells
    /// honor AXEnhancedUserInterface, the attribute VoiceOver sets. Native apps are left untouched.
    func enable(pid: pid_t) -> Outcome {
        lock.lock()
        let first = requested.insert(pid).inserted
        if requested.count > 256 { requested = [pid] }
        lock.unlock()
        guard first else { return Outcome(newlyEnabled: false, summary: "already") }
        guard Self.isChromiumBased(pid: pid) else { return Outcome(newlyEnabled: false, summary: "native") }
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        let manual = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let enhanced = AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return Outcome(newlyEnabled: manual == .success || enhanced == .success,
                       summary: "manual:\(manual.rawValue),enhanced:\(enhanced.rawValue)")
    }

    private static func isChromiumBased(pid: pid_t) -> Bool {
        guard let bundle = NSRunningApplication(processIdentifier: pid)?.bundleURL else { return false }
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: frameworks.path)) ?? []
        return names.contains { name in
            guard name.hasSuffix(".framework") else { return false }
            if ["Electron", "Chromium", "Chrome"].contains(where: { name.contains($0) }) { return true }
            let framework = frameworks.appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: framework.appendingPathComponent("Helpers").path)
        }
    }
}
