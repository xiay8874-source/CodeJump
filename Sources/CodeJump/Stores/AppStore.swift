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
    private var hotKey: HotKeyService?
    private var watcher: ProjectWatcher?
    private var refreshTask: Task<Void, Never>?
    private var searchGeneration = 0
    private var indexGeneration = 0
    private var editorProcess: Process?
    private var pendingLink: URL?
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

    func start() {
        hotKey = HotKeyService { [weak self] in self?.capturePointer() }
        registerShortcut()
        configureWatcher()
        indexing = true
        Task {
            if let count = await service.restore(projects: preferences.projects) { fileCount = count }
            refreshIndex()
        }
        showMainWindow()
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
        checkPermission()
        guard accessibilityGranted else { error = "需要辅助功能权限，才能读取鼠标指向的引用。"; showMainWindow(); return }
        guard !busy else { return }
        guard !preferences.projects.filter(\.enabled).isEmpty else { error = "请先导入至少一个项目。"; showMainWindow(); return }
        guard !indexing && indexReady else { error = "项目索引尚未就绪，完成更新后再按快捷键。"; showMainWindow(); return }
        let point = CGEvent(source: nil)?.location ?? .zero
        let name = NSWorkspace.shared.frontmostApplication?.localizedName ?? "应用"
        busy = true; error = nil
        Task {
            let capture = await Task.detached(priority: .userInitiated) {
                HoverReader.capture(x: point.x, y: point.y, application: name)
            }.value
            captureMilliseconds = capture.elapsedMilliseconds
            for fragment in capture.fragments {
                var references = ReferenceParser.parse(fragment.text)
                if references.isEmpty, fragment.precise, let label = ReferenceParser.parseClassLabel(fragment.text) {
                    references = [label]
                }
                if fragment.origin == "引用链接" {
                    let labels = capture.fragments.filter { $0.origin != "引用链接" }.map(\.text)
                    references = references.map { ReferenceContext.enrich($0, labels: labels) }
                }
                guard !references.isEmpty else { continue }
                let result = await service.resolve(references)
                guard !result.0.isEmpty else { continue }
                captureText = fragment.text; captureOrigin = "\(capture.application) · \(fragment.origin)"
                finishResolution(references, result: result, precise: fragment.precise)
                return
            }
            busy = false; captureText = capture.fragments.first?.text ?? ""; captureOrigin = name
            error = "没有读到代码引用。请选中完整引用再试，或在定位框粘贴路径。"
            showMainWindow()
        }
    }

    func searchManually() {
        guard !indexing && indexReady else { error = "请等待索引完成，或重新索引。"; return }
        var references = ReferenceParser.parse(query)
        if references.isEmpty, let label = ReferenceParser.parseClassLabel(query) { references = [label] }
        guard !references.isEmpty else { error = "未识别到文件路径、类名或方法引用。"; return }
        busy = true; error = nil
        Task { await resolve(references, text: query, origin: "手动输入", precise: true) }
    }

    func handle(url: URL) {
        guard url.scheme == "codejump", url.host == "open" else { return }
        query = url.absoluteString
        guard indexReady && !indexing else { pendingLink = url; showMainWindow(); return }
        // External links always expose the resolved destination before opening.
        let references = ReferenceParser.parse(query)
        guard !references.isEmpty else { error = "跳转链接无效。"; showMainWindow(); return }
        Task { await resolve(references, text: query, origin: "跳转链接", precise: false) }
    }

    private func resolve(_ references: [CodeReference], text: String, origin: String, precise: Bool) async {
        searchGeneration += 1
        let generation = searchGeneration
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
            error = "在已启用项目中没有找到匹配。可补充项目、完整路径或类名。"
            showMainWindow(); return
        }
        if precise && references.count == 1 && candidates.count == 1 && !candidates[0].requiresConfirmation && !preferences.previewBeforeOpening {
            open(candidates[0])
        } else {
            windows.showCandidates()
        }
    }

    func choose(_ index: Int) {
        guard candidates.indices.contains(index) else { return }
        open(candidates[index])
    }

    func dismissCandidates() { windows.dismissCandidates() }

    private func open(_ candidate: JumpCandidate) {
        guard editorProcess?.isRunning != true else {
            error = "上一次请求仍在等待编辑器响应，请稍后再试。"; showMainWindow(); return
        }
        do {
            let plan = try EditorLaunchPlan.make(candidate: candidate, editor: preferences.editor,
                applicationPath: preferences.customApplicationPath)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: plan.executable)
            process.arguments = plan.arguments
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] task in
                let exitStatus = task.terminationStatus
                Task { @MainActor in
                    guard let self else { return }
                    self.editorProcess = nil
                    if exitStatus != 0 {
                        self.error = "编辑器启动请求失败（退出码 \(exitStatus)），请检查编辑器状态或安装位置。"
                        self.status = "编辑器未完成启动请求"
                    }
                }
            }
            try process.run()
            editorProcess = process
            windows.dismissCandidates()
            lastOpened = "\(candidate.project.name) / \(candidate.relativePath)\(candidate.line.map { ":\($0)" } ?? "")"
            status = "已发送到 \(preferences.editor.displayTitle)"
            let processID = process.processIdentifier
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self, self.editorProcess?.processIdentifier == processID, self.editorProcess?.isRunning == true else { return }
                self.status = "编辑器仍在处理请求，请检查其状态"
            }
        } catch {
            self.error = "打开失败：\(error.localizedDescription)"; showMainWindow()
        }
    }
}

extension EditorKind {
    var displayTitle: String {
        switch self { case .idea: "IntelliJ IDEA"; case .vscode: "VS Code"; case .cursor: "Cursor"; case .zed: "Zed" }
    }
}
