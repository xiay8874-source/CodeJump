import AppKit
import CodeJumpCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 38)).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 5) {
                    Text("CodeJump").font(.largeTitle.bold())
                    Text("指向代码引用，按 \(store.shortcutLabel)，回到编辑器。")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("收起窗口") { NSApp.keyWindow?.close() }
                    .help("应用继续在菜单栏运行")
            }
            if let error = store.error {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(error).textSelection(.enabled)
                    Spacer()
                    Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }
            permissionRow
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Label("项目范围", systemImage: "folder") .font(.headline)
                        Spacer()
                        if store.indexing { ProgressView().controlSize(.small) }
                        Text("\(store.fileCount.formatted()) 个文件").foregroundStyle(.secondary)
                        Button("切换项目 \(store.projectShortcutLabel)") { store.showProjectPicker() }
                        Button("添加项目…") { store.importProjects() }
                    }
                    if store.preferences.projects.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "folder.badge.plus").font(.system(size: 25))
                            Text("把项目文件夹拖到这里，或点击“添加项目”")
                            Text("只在勾选的项目中查找，重名时由你选择。")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach($store.preferences.projects) { $project in
                                    ProjectRow(project: $project, onChange: store.projectsChanged) {
                                        store.preferences.projects.removeAll { $0.id == project.id }
                                        store.projectsChanged()
                                    }
                                    Divider()
                                }
                            }
                        }.frame(height: min(220, CGFloat(store.preferences.projects.count) * 82))
                    }
                }.padding(8)
            }.dropDestination(for: URL.self) { urls, _ in store.addProjects(urls); return true }
            HStack(alignment: .top, spacing: 26) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("默认编辑器").font(.headline)
                    Picker("默认编辑器", selection: $store.preferences.editor) {
                        ForEach(EditorKind.allCases, id: \.self) { Text($0.displayTitle).tag($0) }
                    }.labelsHidden().frame(width: 190)
                        .onChange(of: store.preferences.editor) { _, _ in
                            store.preferences.customApplicationPath = nil; store.persist()
                        }
                    Button(store.preferences.customApplicationPath == nil ? "选择安装位置…" : "已指定安装位置…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.application]
                        panel.title = "选择 \(store.preferences.editor.displayTitle) 应用"
                        if panel.runModal() == .OK {
                            store.preferences.customApplicationPath = panel.url?.path; store.persist()
                        }
                    }.font(.caption)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("触发方式").font(.headline)
                    Picker("快捷键", selection: $store.preferences.commandOptionShortcut) {
                        Text("⌥J").tag(false); Text("⌘⌥J").tag(true)
                    }.pickerStyle(.segmented).frame(width: 150)
                        .onChange(of: store.preferences.commandOptionShortcut) { _, _ in store.persist(); store.registerShortcut() }
                    Text("代码 \(store.shortcutLabel) · 项目 \(store.projectShortcutLabel)")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("每次先显示定位预览", isOn: $store.preferences.previewBeforeOpening)
                        .font(.caption).onChange(of: store.preferences.previewBeforeOpening) { _, _ in store.persist() }
                }
                Spacer()
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("手动定位").font(.headline)
                HStack {
                    TextField("文件路径、Class.java:128 或 Class.method", text: $store.query)
                        .textFieldStyle(.roundedBorder).onSubmit { store.searchManually() }
                    Button("定位") { store.searchManually() }
                        .disabled(store.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.indexing || store.busy)
                }
                if !store.lastOpened.isEmpty { Text(store.lastOpened).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            DisclosureGroup("最近一次定位信息") {
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.captureOrigin.isEmpty ? "按快捷键后显示识别结果" : store.captureOrigin)
                    Text(store.captureText).font(.system(.caption, design: .monospaced))
                        .lineLimit(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Text("读取 \(store.captureMilliseconds, specifier: "%.0f") ms · 查询 \(store.queryMilliseconds, specifier: "%.1f") ms · 索引 \(store.indexMilliseconds, specifier: "%.0f") ms")
                        .foregroundStyle(.secondary).font(.caption)
                    Button("测试悬停（3 秒后读取鼠标位置）") { store.testPointerAfterDelay() }
                }.padding(.top, 6)
            }.font(.caption)
            HStack {
                Circle().fill(store.indexing ? .orange : (store.indexReady ? .green : .gray)).frame(width: 6, height: 6)
                Text(store.status).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("重建索引") { store.refreshIndex() }.font(.caption).disabled(store.indexing)
            }
        }.padding(26).frame(minWidth: 640, idealWidth: 720, minHeight: 640)
    }

    private var permissionRow: some View {
        HStack {
            Image(systemName: store.accessibilityGranted ? "checkmark.shield" : "hand.point.up.left")
            VStack(alignment: .leading, spacing: 3) {
                Text(store.accessibilityGranted ? "悬停读取已就绪" : "开启辅助功能权限以使用悬停跳转").font(.subheadline.weight(.medium))
                Text("仅按快捷键时读取引用；普通单击沿用原来的行为。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !store.accessibilityGranted { Button("前往授权") { store.requestPermission() } }
            Button { store.checkPermission() } label: { Image(systemName: "arrow.clockwise") }.help("刷新权限状态")
        }.padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct ProjectRow: View {
    @Binding var project: ProjectRoot
    @State private var aliasDraft: String
    @FocusState private var aliasFocused: Bool
    let onChange: () -> Void
    let onRemove: () -> Void

    init(project: Binding<ProjectRoot>, onChange: @escaping () -> Void, onRemove: @escaping () -> Void) {
        _project = project
        _aliasDraft = State(initialValue: project.wrappedValue.aliases.joined(separator: ", "))
        self.onChange = onChange; self.onRemove = onRemove
    }

    private func commitAliases() {
        let aliases = aliasDraft.replacingOccurrences(of: "，", with: ",").split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard project.aliases != aliases else { return }
        project.aliases = aliases; onChange()
    }
    var body: some View {
        HStack(spacing: 10) {
            Toggle("参与搜索", isOn: $project.enabled).labelsHidden().toggleStyle(.checkbox)
                .onChange(of: project.enabled) { _, _ in onChange() }
            VStack(alignment: .leading, spacing: 4) {
                Text(project.name).font(.system(.body, design: .monospaced).weight(.medium))
                Text(project.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .help(project.path)
                TextField("别名，例如 alpha，多个用逗号分隔", text: $aliasDraft)
                    .textFieldStyle(.plain).font(.caption).focused($aliasFocused)
                    .onSubmit(commitAliases).onChange(of: aliasFocused) { _, focused in if !focused { commitAliases() } }
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("移出搜索范围")
        }.padding(.vertical, 10)
    }
}
