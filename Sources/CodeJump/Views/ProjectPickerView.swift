import CodeJumpCore
import SwiftUI

struct ProjectPickerView: View {
    @ObservedObject var store: AppStore
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("切换项目", systemImage: "folder").font(.headline)
                Spacer()
                Text(store.preferences.editor.displayTitle).font(.caption).foregroundStyle(.secondary)
            }
            TextField("搜索项目、别名或路径", text: $store.projectQuery)
                .textFieldStyle(.roundedBorder).focused($searchFocused)
                .onChange(of: store.projectQuery) { _, _ in store.selectedProjectIndex = 0 }
            ScrollViewReader { proxy in
                ScrollView {
                    if store.rankedProjects.isEmpty {
                        Text("没有匹配的项目").foregroundStyle(.secondary).padding(20)
                    }
                    VStack(spacing: 4) {
                        ForEach(Array(store.rankedProjects.enumerated()), id: \.element.id) { index, project in
                            Button { store.chooseProject(at: index) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "folder.fill").foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(project.name).font(.subheadline.weight(.semibold))
                                        Text(project.path).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    Spacer()
                                    if let usage = store.preferences.projectUsage[project.id.uuidString], let date = usage.lastOpened {
                                        Text(date, style: .relative).font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if index < 9 { Text("⌘\(index + 1)").font(.caption2).foregroundStyle(.secondary) }
                                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.selectedProjectIndex == index ? Color.accentColor.opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
                            }.buttonStyle(.plain).id(index)
                        }
                    }
                }.frame(maxHeight: 340)
                    .onChange(of: store.selectedProjectIndex) { _, value in proxy.scrollTo(value) }
            }
            Divider()
            HStack {
                Text("最近常选优先 · ↑↓ 选择 · 回车切换 · Esc 关闭")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("管理项目") { store.dismissCandidates(); store.showMainWindow() }.controlSize(.small)
            }
        }.padding(18).frame(width: 570)
            .onAppear { searchFocused = true }
    }
}
