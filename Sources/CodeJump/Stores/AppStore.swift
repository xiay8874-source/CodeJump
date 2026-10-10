import AppKit
import CodeJumpCore
import Combine
import OSLog
import Darwin

struct Preferences: Codable {
    var projects: [ProjectRoot] = []
    var editor: EditorKind = .idea
    var customApplicationPath: String? = nil
    var commandOptionShortcut = false
    var previewBeforeOpening = false
    var projectUsage: [String: ProjectUsage] = [:]
    var recentJumps: [RecentJump] = []
    var rememberSourceProject = false
    var sourceProjects: [String: UUID] = [:]
    var ideaPluginEnabled = false

    init() {}
    private enum CodingKeys: String, CodingKey {
        case projects, editor, customApplicationPath, commandOptionShortcut, previewBeforeOpening, projectUsage, recentJumps, rememberSourceProject, sourceProjects, ideaPluginEnabled
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([ProjectRoot].self, forKey: .projects) ?? []
        editor = try values.decodeIfPresent(EditorKind.self, forKey: .editor) ?? .idea
        customApplicationPath = try values.decodeIfPresent(String.self, forKey: .customApplicationPath)
        commandOptionShortcut = try values.decodeIfPresent(Bool.self, forKey: .commandOptionShortcut) ?? false
        previewBeforeOpening = try values.decodeIfPresent(Bool.self, forKey: .previewBeforeOpening) ?? false
        projectUsage = try values.decodeIfPresent([String: ProjectUsage].self, forKey: .projectUsage) ?? [:]
        recentJumps = Array((try values.decodeIfPresent([RecentJump].self, forKey: .recentJumps) ?? []).prefix(30))
        rememberSourceProject = try values.decodeIfPresent(Bool.self, forKey: .rememberSourceProject) ?? false
        sourceProjects = try values.decodeIfPresent([String: UUID].self, forKey: .sourceProjects) ?? [:]
        ideaPluginEnabled = try values.decodeIfPresent(Bool.self, forKey: .ideaPluginEnabled) ?? false
    }
}

@MainActor final class AppStore: ObservableObject {
    static let shared = AppStore()
    @Published var preferences: Preferences
    @Published var indexing = false
    @Published var indexReady = false
    @Published var fileCount = 0
    @Published var indexMilliseconds = 0.0
    @Published var queryMilliseconds = 0.0
    @Published var captureMilliseconds = 0.0
    @Published var status = "准备索引…"
    @Published var error: String?
    @Published var captureText = ""
    @Published var captureOrigin = ""
    @Published var candidates: [JumpCandidate] = []
    @Published var selectedIndex = 0
    @Published var query = ""
    @Published var busy = false
    @Published var accessibilityGranted = HoverReader.isTrusted
    @Published var shortcutRegistered = false
    @Published var lastOpened = ""
    @Published var projectQuery = ""
    @Published var selectedProjectIndex = 0
    @Published var scopeProjectID: UUID? = nil
    @Published var previewLines: [PreviewLine] = []
    @Published var previewError: String?
    private var sourceApplicationID: String?
    private var lastReferences: [CodeReference] = []
    private let ideaBridge = IDEABridge()
    @Published var pluginStatus = "未检查"
    private var hotKey: HotKeyService?
    private var watcher: ProjectWatcher?
    private var refreshTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var indexGeneration = 0
    private var lastLaunchTime = Date.distantPast
    private var currentLaunchID: UUID?
    private var pendingLink: URL?
    private var interactionOriginPID: pid_t?
    private let service: IndexService
    private let settingsURL: URL
    private lazy var windows = WindowPresenter(store: self)
    private let log = Logger(subsystem: "com.xiay8874.CodeJump", category: "performance")

    private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodeJump", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settingsURL = directory.appendingPathComponent("settings.json")
        service = IndexService(cacheURL: directory.appendingPathComponent("index-v1.json"))
        if let data = try? Data(contentsOf: settingsURL), let saved = try? JSONDecoder().decode(Preferences.self, from: data) {
            preferences = saved
        } else {
            preferences = Preferences()
        }
    }

    var shortcutLabel: String { preferences.commandOptionShortcut ? "⌘⌥J" : "⌥J" }
    var projectShortcutLabel: String { preferences.commandOptionShortcut ? "⌘⌥P" : "⌥P" }
    var homeShortcutLabel: String { preferences.commandOptionShortcut ? "⌘⌥H" : "⌥H" }
    var rankedProjects: [ProjectRoot] {
        ProjectRanking.sorted(projects: preferences.projects, usage: preferences.projectUsage, query: projectQuery)
    }

    func start() {
        hotKey = HotKeyService(navigate: { [weak self] in self?.capturePointer() },
                              chooseProject: { [weak self] in self?.showProjectPicker() },
                              showHome: { [weak self] in self?.toggleMainWindow() })
        registerShortcut()
        configureWatcher()
        indexing = true
        Task {
            if let count = await service.restore(projects: preferences.projects) { fileCount = count }
            refreshIndex()
        }
        if preferences.projects.isEmpty { showMainWindow() }
    }

    func persist() {
        do { try JSONEncoder().encode(preferences).write(to: settingsURL, options: .atomic) }
        catch { self.error = "保存设置失败：\(error.localizedDescription)" }
    }

    func registerShortcut() {
        let failed = hotKey?.register(commandOption: preferences.commandOptionShortcut) ?? ["J", "P", "H"]
        shortcutRegistered = !failed.contains("J")
        if !failed.isEmpty { error = "以下快捷键被占用：" + failed.map { (preferences.commandOptionShortcut ? "⌘⌥" : "⌥") + $0 }.joined(separator: "、") + "。其他快捷键仍可使用。" }
    }

    func checkPermission() { accessibilityGranted = HoverReader.isTrusted }
    func requestPermission() {
        HoverReader.requestPermission()
        checkPermission()
        if !accessibilityGranted, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func showMainWindow() { checkPermission(); windows.showMain() }
    func toggleMainWindow() { checkPermission(); windows.toggleMain() }

    private func recordInteractionOrigin() {
        let application = NSWorkspace.shared.frontmostApplication
        if application?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            sourceApplicationID = application?.bundleIdentifier
        }
        let pid = application?.processIdentifier
        interactionOriginPID = pid == ProcessInfo.processInfo.processIdentifier ? nil : pid
    }

    private func feedback(_ message: String) {
        error = message
        status = message
        windows.showFeedback(message)
    }

    func showProjectPicker() {
        searchGeneration += 1; busy = false
        recordInteractionOrigin()
        guard !preferences.projects.filter(\.enabled).isEmpty else {
            feedback("尚未导入项目，请从菜单栏打开“项目与设置”。"); return
        }
        projectQuery = ""; selectedProjectIndex = 0
        windows.showProjects(originPID: interactionOriginPID)
    }

    func chooseProject(at index: Int) {
        let projects = rankedProjects
        guard projects.indices.contains(index) else { return }
        let project = projects[index]
        windows.dismissCandidates()
        searchGeneration += 1
        let generation = searchGeneration
        let editor = preferences.editor
        let configured = preferences.projects
        let applicationPath = preferences.customApplicationPath
        Task {
            // Revalidate the imported root before both AX focus and CLI fallback.
            do {
                let plan = try EditorLaunchPlan.project(project: project, editor: editor, applicationPath: applicationPath)
                let focused = await Task.detached(priority: .userInitiated) {
                    await ProjectWindowFocus.focus(project: project, editor: editor, configuredProjects: configured, applicationPath: applicationPath)
                }.value
                guard generation == searchGeneration else { return }
                if !focused { try launch(plan, editor: editor) }
                var usage = preferences.projectUsage[project.id.uuidString] ?? ProjectUsage()
                usage.record(at: Date())
                preferences.projectUsage[project.id.uuidString] = usage
                persist()
                status = focused ? "已切换到 \(project.name)" : "已请求打开 \(project.name)"
            } catch {
                guard generation == searchGeneration else { return }
                feedback("项目打开失败：\(error.localizedDescription)")
            }
        }
    }

    func testPointerAfterDelay() {
        status = "请在 3 秒内将鼠标移到代码引用上…"
        Task { try? await Task.sleep(for: .seconds(3)); capturePointer() }
    }

    func importProjects() {
        let panel = NSOpenPanel()
        panel.title = "选择参与搜索的项目文件夹"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        addProjects(panel.urls)
    }

    func addProjects(_ urls: [URL]) {
        for url in urls {
            guard let resolved = url.path.withCString({ realpath($0, nil) }) else { continue }
            let canonical = URL(fileURLWithPath: String(cString: resolved))
            free(resolved)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: canonical.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  !preferences.projects.contains(where: { $0.path == canonical.path }) else { continue }
            preferences.projects.append(ProjectRoot(name: canonical.lastPathComponent, path: canonical.path))
        }
        projectsChanged()
    }

    func projectsChanged() {
        if let id = scopeProjectID, !preferences.projects.contains(where: { $0.id == id && $0.enabled }) { scopeProjectID = nil }
        persist(); configureWatcher(); refreshIndex()
    }

    private func configureWatcher() {
        watcher = ProjectWatcher(paths: preferences.projects.filter(\.enabled).map(\.path)) { [weak self] paths in
            Task { @MainActor in self?.refreshIndex(changedPaths: paths) }
        }
    }

    func refreshIndex(changedPaths: [String]? = nil) {
        indexGeneration += 1
        let generation = indexGeneration
        // A superseded incremental batch must never be lost: coalesce with a full refresh.
        let paths = indexing || (changedPaths?.count ?? 0) > 256 ? nil : changedPaths
        refreshTask?.cancel()
        indexing = true; indexReady = false
        let projects = preferences.projects
        status = "正在更新项目索引…"
        refreshTask = Task {
            do {
                let result = try await service.refresh(projects: projects, changedPaths: paths, generation: generation)
                guard generation == indexGeneration, !Task.isCancelled else { return }
                fileCount = result.0; indexMilliseconds = result.1; indexing = false; indexReady = true
                status = projects.isEmpty ? "导入项目后即可开始" : "索引就绪 · \(result.0.formatted()) 个文件"
                log.info("index files=\(result.0) elapsed_ms=\(result.1)")
                if let link = pendingLink { pendingLink = nil; handle(url: link) }
            } catch {
                guard generation == indexGeneration else { return }
                indexing = false; indexReady = false; self.error = "索引失败：\(error.localizedDescription)"
                status = "索引未就绪，请重建"
            }
        }
    }

    func capturePointer() {
        guard !busy else { return }
        checkPermission()
        recordInteractionOrigin()
        guard accessibilityGranted else { feedback("请在菜单栏“项目与设置”中开启辅助功能权限。"); return }
        guard !preferences.projects.filter(\.enabled).isEmpty else { feedback("尚未导入项目，请从菜单栏打开“项目与设置”。"); return }
        guard !indexing && indexReady else { feedback("项目索引正在准备，完成后再试。"); return }
        let point = CGEvent(source: nil)?.location ?? .zero
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "应用"
        busy = true; error = nil
        searchGeneration += 1
        let generation = searchGeneration
        Task {
            let capture = await Task.detached(priority: .userInitiated) {
                HoverReader.capture(x: point.x, y: point.y, application: name)
            }.value
            guard generation == searchGeneration else { return }
            captureMilliseconds = capture.elapsedMilliseconds
            var primary: [CodeReference] = []
            var fallback: [CodeReference] = []
            var primaryText = ""
            var primaryOrigin = ""
            for fragment in capture.fragments {
                var references = ReferenceSelection.select(text: fragment.text, utf16Offset: fragment.utf16Offset)
                if fragment.precise, fragment.utf16Offset == nil,
                   let label = ReferenceParser.parseExplicitLabel(fragment.text) { references = [label] }
                if fragment.origin == "引用链接" {
                    references = references.map { ReferenceContext.enrich($0, labels: fragment.labels) }
                }
                guard !references.isEmpty else { continue }
                if primary.isEmpty, fragment.precise, !references.contains(where: \.isFallback) {
                    primary = references; primaryText = fragment.text; primaryOrigin = fragment.origin
                } else {
                    fallback += references.map { var ref = $0; ref.isFallback = true; return ref }
                }
            }
            if !primary.isEmpty {
                let result = await resolveScoped(primary)
                guard generation == searchGeneration else { return }
                captureText = primaryText; captureOrigin = "\(capture.application) · \(primaryOrigin)"
                if !result.0.isEmpty {
                    finishResolution(primary, result: result, precise: true)
                    return
                }
            }
            if !fallback.isEmpty {
                let result = await resolveScoped(Array(fallback.prefix(128)))
                guard generation == searchGeneration else { return }
                if !result.0.isEmpty {
                    captureText = primaryText.isEmpty ? (capture.fragments.first?.text ?? "") : primaryText
                    captureOrigin = "\(capture.application) · 邻近引用（精准目标未匹配）"
                    finishResolution(fallback, result: result, precise: false)
                    return
                }
            }
            busy = false; captureText = capture.fragments.first?.text ?? ""; captureOrigin = name
            lastReferences = primary + fallback; candidates = []
            if !primary.isEmpty {
                feedback("已识别引用，但没有找到声明。裸方法名需要已连接的 IDEA 插件和已打开的项目。")
            } else { feedback("未识别到代码位置，选中完整引用后按 \(shortcutLabel) 重试。") }
        }
    }

    func searchManually() {
        recordInteractionOrigin()
        guard !indexing && indexReady else { feedback("请等待索引完成，或重新索引。"); return }
        var references = ReferenceParser.parse(query)
        if references.isEmpty, let label = ReferenceParser.parseExplicitLabel(query) { references = [label] }
        guard !references.isEmpty else {
            captureText = query; captureOrigin = "手动输入 · 未识别"; lastReferences = []; candidates = []
            feedback("未识别到文件路径、类名或方法引用。"); return
        }
        busy = true; error = nil
        searchGeneration += 1
        let generation = searchGeneration
        let text = query
        Task { await resolve(references, text: text, origin: "手动输入", precise: true, generation: generation) }
    }

    func handle(url: URL) {
        guard url.scheme == "codejump", url.host == "open" else { return }
        recordInteractionOrigin()
        query = url.absoluteString
        guard indexReady && !indexing else { pendingLink = url; feedback("索引准备好后会显示定位结果。"); return }
        // External links always expose the resolved destination before opening.
        let references = ReferenceParser.parse(query)
        guard !references.isEmpty else { feedback("跳转链接无效。"); return }
        searchGeneration += 1
        let generation = searchGeneration
        let text = query
        Task { await resolve(references, text: text, origin: "跳转链接", precise: false, generation: generation) }
    }

    private func resolve(_ references: [CodeReference], text: String, origin: String, precise: Bool, generation: Int) async {
        guard generation == searchGeneration else { return }
        captureText = text; captureOrigin = origin
        let result = await resolveScoped(references)
        guard generation == searchGeneration else { return }
        finishResolution(references, result: result, precise: precise)
    }

    private func resolveScoped(_ references: [CodeReference]) async -> ([JumpCandidate], Double) {
        let result = await service.resolve(references)
        let enabled = preferences.projects.filter { $0.enabled && (scopeProjectID == nil || $0.id == scopeProjectID) }
        let plugin = preferences.ideaPluginEnabled && preferences.editor == .idea
            ? await ideaBridge.resolve(references, projects: enabled, applicationPath: preferences.customApplicationPath) : []
        let scoped = plugin + result.0.filter { candidate in
            (scopeProjectID == nil || candidate.project.id == scopeProjectID)
            && !plugin.contains(where: { $0.project.id == candidate.project.id && $0.absolutePath == candidate.absolutePath && $0.line == candidate.line })
        }
        let preferred = preferences.rememberSourceProject ? sourceApplicationID.flatMap { preferences.sourceProjects[$0] } : nil
        let sorted = scoped.enumerated().sorted {
            let left = $0.element.project.id == preferred, right = $1.element.project.id == preferred
            return left == right ? $0.offset < $1.offset : left
        }.map(\.element)
        return (sorted, result.1)
    }

    private func finishResolution(_ references: [CodeReference], result: ([JumpCandidate], Double), precise: Bool) {
        lastReferences = references
        previewLines = []; previewError = nil
        queryMilliseconds = result.1
        candidates = result.0; selectedIndex = 0; busy = false
        log.info("resolve refs=\(references.count) candidates=\(result.0.count) elapsed_ms=\(result.1)")
        guard !candidates.isEmpty else {
            feedback(references.contains(where: { $0.path == nil && $0.symbol?.first?.isLowercase == true && !($0.symbol?.contains(".") ?? false) })
                ? "已识别方法名，但未找到声明。请确认 IDEA 插件已连接、目标项目已打开，或补充“类名.方法名”。"
                : "已识别引用，但已启用项目中没有精确匹配或类名后缀候选，请核对完整类名。"); return
        }
        if precise && references.count == 1 && candidates.count == 1 && !candidates[0].requiresConfirmation && !preferences.previewBeforeOpening {
            open(candidates[0])
        } else {
            windows.showCandidates(originPID: interactionOriginPID)
        }
    }

    func choose(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        open(candidates[index])
    }

    func dismissCandidates(restoreFocus: Bool = true) {
        searchGeneration += 1; busy = false
        windows.dismissCandidates(restoreFocus: restoreFocus)
    }

    private func open(_ candidate: JumpCandidate) {
        // A newly started IDE may keep this process alive for hours. Its lifetime
        // must never lock subsequent navigation; only debounce accidental double triggers.
        guard Date().timeIntervalSince(lastLaunchTime) >= 0.35 else { return }
        if candidate.pluginTarget != nil {
            lastLaunchTime = Date()
            Task {
                do {
                    try await ideaBridge.navigate(candidate, applicationPath: preferences.customApplicationPath)
                    windows.dismissCandidates(); recordOpened(candidate)
                    status = "已请求 IDEA 按当前声明定位"
                } catch { feedback("IDEA 插件目标已失效或未连接，请重新定位。") }
            }
            return
        }
        do {
            guard preferences.projects.contains(where: { $0.id == candidate.project.id && $0.enabled && $0.path == candidate.project.path }) else {
                feedback("项目范围已变化，请重新定位。"); return
            }
            let plan = try EditorLaunchPlan.make(candidate: candidate, editor: preferences.editor,
                applicationPath: preferences.customApplicationPath)
            try launch(plan, editor: preferences.editor)
            windows.dismissCandidates()
            recordOpened(candidate)
        } catch {
            feedback("打开失败：\(error.localizedDescription)")
        }
    }

    private func recordOpened(_ candidate: JumpCandidate) {
        preferences.recentJumps.removeAll { $0.projectID == candidate.project.id && $0.path == candidate.absolutePath && $0.symbol == candidate.symbol && $0.line == candidate.line }
        preferences.recentJumps.insert(RecentJump(candidate: candidate), at: 0)
        preferences.recentJumps = Array(preferences.recentJumps.prefix(30))
        if preferences.rememberSourceProject, let sourceApplicationID {
            preferences.sourceProjects[sourceApplicationID] = candidate.project.id
        }
        persist()
        lastOpened = "\(candidate.project.name) / \(candidate.relativePath)\(candidate.line.map { ":\($0)" } ?? "")"
    }

    func checkPlugin() {
        Task {
            let count = await ideaBridge.connected(applicationPath: preferences.customApplicationPath)
            pluginStatus = count > 0 ? "已连接 \(count) 个 IDEA 实例" : "未连接；安装插件后在 IDEA 的 Tools 菜单启动 CodeJump Bridge"
        }
    }

    func loadPreview() async {
        guard candidates.indices.contains(selectedIndex) else { return }
        let candidate = candidates[selectedIndex]
        previewLines = []; previewError = nil
        if let target = candidate.pluginTarget {
            let lines = await ideaBridge.preview(target)
            guard !Task.isCancelled, candidates.indices.contains(selectedIndex), candidates[selectedIndex].id == candidate.id else { return }
            previewLines = lines
            if lines.isEmpty { previewError = "此 IDEA 声明没有可用源码预览" }
            return
        }
        let result = await Task.detached(priority: .userInitiated) { Result { try SourcePreview.read(candidate) } }.value
        guard !Task.isCancelled, candidates.indices.contains(selectedIndex), candidates[selectedIndex].id == candidate.id else { return }
        switch result {
        case .success(let lines): previewLines = lines
        case .failure: previewError = "无法预览：文件已变化、超出大小上限或不是 UTF-8 文本。"
        }
    }

    func reopen(_ recent: RecentJump) {
        guard preferences.projects.contains(where: { $0.id == recent.projectID && $0.enabled }) else {
            feedback("此记录的项目已移除或停用。"); return
        }
        recordInteractionOrigin(); searchGeneration += 1
        let generation = searchGeneration
        Task {
            let reference = recent.path.hasPrefix("jar://")
                ? CodeReference(source: recent.path, symbol: recent.symbol, isFallback: true) : recent.reference
            let local = await service.resolve([reference])
            let project = preferences.projects.filter { $0.id == recent.projectID && $0.enabled }
            let plugin = preferences.ideaPluginEnabled && preferences.editor == .idea
                ? await ideaBridge.resolve([reference], projects: project, applicationPath: preferences.customApplicationPath) : []
            let result = (plugin + local.0, local.1)
            guard generation == searchGeneration else { return }
            captureText = recent.path; captureOrigin = "最近跳转 · 已重新核对当前源码"
            finishResolution([recent.reference], result: (result.0.filter { $0.project.id == recent.projectID }, result.1), precise: false)
        }
    }

    func exportRecognitionFeedback() {
        let panel = NSSavePanel()
        panel.title = "保存本次识别反馈（仅本地）"
        panel.nameFieldStringValue = "CodeJump-feedback.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        struct Report: Encodable {
            var capturedText: String; var origin: String
            var references: [CodeReference]; var candidates: [JumpCandidate]
            var expectedLocation = "请填写期望打开的文件、方法或行号"
        }
        do {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Report(capturedText: captureText, origin: captureOrigin,
                references: lastReferences, candidates: candidates.map {
                    var value = $0; value.pluginTarget = nil; value.pluginEndpoint = nil; return value
                })).write(to: url, options: .atomic)
            status = "识别反馈已保存到本地"
        } catch { self.error = "反馈保存失败：\(error.localizedDescription)" }
    }

    private func launch(_ plan: EditorLaunchPlan, editor: EditorKind) throws {
            let process = Process()
            let requestID = UUID()
            let requestedAt = Date()
            process.executableURL = URL(fileURLWithPath: plan.executable)
            process.arguments = plan.arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] task in
                let exitStatus = task.terminationStatus
                Task { @MainActor in
                    guard let self, self.currentLaunchID == requestID else { return }
                    if exitStatus != 0 && Date().timeIntervalSince(requestedAt) < 30 {
                        self.feedback("编辑器启动失败（退出码 \(exitStatus)），请检查安装位置。")
                    }
                }
            }
            try process.run()
            currentLaunchID = requestID
            lastLaunchTime = requestedAt
            status = "已发送到 \(editor.displayTitle)"
    }
}

extension EditorKind {
    var displayTitle: String {
        switch self { case .idea: "IntelliJ IDEA"; case .vscode: "VS Code"; case .cursor: "Cursor"; case .zed: "Zed" }
    }
}
