import CodeJumpCore
import SwiftUI

struct CandidateView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "arrow.up.forward.app").foregroundStyle(.tint)
                Text(store.candidates.count == 1 ? "确认打开位置" : "选择打开位置").font(.headline)
                Spacer()
                Text(store.preferences.editor.displayTitle).font(.caption).foregroundStyle(.secondary)
            }
            Text(store.captureOrigin).font(.caption2).foregroundStyle(.secondary)
            Text(store.captureText).font(.system(.caption, design: .monospaced)).lineLimit(2)
                .foregroundStyle(.secondary).textSelection(.enabled)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(Array(store.candidates.enumerated()), id: \.element.id) { offset, candidate in
                            Button { store.choose(offset) } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Text(offset < 9 ? "\(offset + 1)" : "·")
                                        .font(.system(.caption, design: .monospaced)).frame(width: 16).padding(.top, 3)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(candidate.project.name).font(.subheadline.bold())
                                            if let line = candidate.line { Text("第 \(line) 行").font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Text(candidate.relativePath).font(.system(.caption, design: .monospaced))
                                            .lineLimit(2).multilineTextAlignment(.leading)
                                        Text(candidate.project.path).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        if !candidate.reason.isEmpty {
                                            Text(candidate.reason).font(.caption)
                                                .foregroundStyle(candidate.requiresConfirmation ? Color.orange : Color.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "arrow.up.right").font(.caption)
                                }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(store.selectedIndex == offset ? Color.accentColor.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(offset).onHover { hovering in if hovering { store.selectedIndex = offset } }
                        }
                    }
                }.frame(height: min(220, CGFloat(store.candidates.count) * 112))
                    .onChange(of: store.selectedIndex) { _, value in proxy.scrollTo(value) }
            }
            Group {
            if let error = store.previewError { Text(error).font(.caption).foregroundStyle(.secondary) }
            else if store.previewLines.isEmpty { Text("正在读取代码预览…").font(.caption).foregroundStyle(.secondary) }
            else {
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(store.previewLines) { line in
                            HStack(alignment: .top, spacing: 10) {
                                Text(String(line.number)).foregroundStyle(.secondary).frame(width: 42, alignment: .trailing)
                                Text(line.text.isEmpty ? " " : line.text).textSelection(.enabled)
                            }.font(.system(size: 11, design: .monospaced))
                                .padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
                                .background(line.highlighted ? Color.accentColor.opacity(0.14) : .clear)
                        }
                    }
                }
            }
            }.frame(height: 135)
            Divider()
            HStack {
                Text("↑↓ 选择 · 回车打开 · 数字快速选择 · Esc 关闭").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("识别反馈…") { store.exportRecognitionFeedback() }.controlSize(.small)
                Button("取消") { store.dismissCandidates() }.controlSize(.small)
                Button("打开位置") { store.choose(store.selectedIndex) }.controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }.padding(18).frame(width: 570)
            .task(id: store.candidates.indices.contains(store.selectedIndex) ? store.candidates[store.selectedIndex].id : "") {
                await store.loadPreview()
            }
    }
}
