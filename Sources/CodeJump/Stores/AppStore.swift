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

    init() {}
    private enum CodingKeys: String, CodingKey {
        case projects, editor, customApplicationPath, commandOptionShortcut, previewBeforeOpening, projectUsage
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decodeIfPresent([ProjectRoot].self, forKey: .projects) ?? []
        editor = try values.decodeIfPresent(EditorKind.self, forKey: .editor) ?? .idea
        customApplicationPath = try values.decodeIfPresent(String.self, forKey: .customApplicationPath)
        commandOptionShortcut = try values.decodeIfPresent(Bool.self, forKey: .commandOptionShortcut) ?? false
        previewBeforeOpening = try values.decodeIfPresent(Bool.self, forKey: .previewBeforeOpening) ?? false
        projectUsage = try values.decodeIfPresent([String: ProjectUsage].self, forKey: .projectUsage) ?? [:]
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
        shortcutRegistered = hotKey?.register(commandOption: preferences.commandOptionShortcut) ?? false
        if !shortcutRegistered { error = "快捷键注册失败。请改用另一个组合，或检查其他应用是否占用。" }
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
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
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
                    await ProjectWindowFocus.focus(project: project, editor: editor, configuredProjects: configured)
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

    func projectsChanged() { persist(); configureWatcher(); refreshIndex() }

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
            for fragment in capture.fragments {
                var references = ReferenceParser.parse(fragment.text)
                if references.isEmpty, fragment.precise, let label = ReferenceParser.parseClassLabel(fragment.text) {
                    references = [label]
                }
                if fragment.origin == "引用链接" {
                    references = references.map { ReferenceContext.enrich($0, labels: fragment.labels) }
                }
                guard !references.isEmpty else { continue }
                let result = await service.resolve(references)
                guard generation == searchGeneration else { return }
                guard !result.0.isEmpty else { continue }
                captureText = fragment.text; captureOrigin = "\(capture.application) · \(fragment.origin)"
                finishResolution(references, result: result, precise: fragment.precise)
                return
            }
            busy = false; captureText = capture.fragments.first?.text ?? ""; captureOrigin = name
            feedback("未识别到代码位置，选中完整引用后按 \(shortcutLabel) 重试。")
        }
    }

    func searchManually() {
        recordInteractionOrigin()
        guard !indexing && indexReady else { feedback("请等待索引完成，或重新索引。"); return }
        var references = ReferenceParser.parse(query)
        if references.isEmpty, let label = ReferenceParser.parseClassLabel(query) { references = [label] }
        guard !references.isEmpty else { feedback("未识别到文件路径、类名或方法引用。"); return }
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
        let result = await service.resolve(references)
        guard generation == searchGeneration else { return }
        finishResolution(references, result: result, precise: precise)
    }

    private func finishResolution(_ references: [CodeReference], result: ([JumpCandidate], Double), precise: Bool) {
        queryMilliseconds = result.1
        candidates = result.0; selectedIndex = 0; busy = false
        log.info("resolve refs=\(references.count) candidates=\(result.0.count) elapsed_ms=\(result.1)")
        guard !candidates.isEmpty else {
            feedback("已启用项目中没有匹配，请补充项目名或完整路径。"); return
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
        do {
            let plan = try EditorLaunchPlan.make(candidate: candidate, editor: preferences.editor,
                applicationPath: preferences.customApplicationPath)
            try launch(plan, editor: preferences.editor)
            windows.dismissCandidates()
            lastOpened = "\(candidate.project.name) / \(candidate.relativePath)\(candidate.line.map { ":\($0)" } ?? "")"
        } catch {
            feedback("打开失败：\(error.localizedDescription)")
        }
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
