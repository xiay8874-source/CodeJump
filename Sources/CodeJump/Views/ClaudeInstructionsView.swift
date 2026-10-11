import SwiftUI

struct ClaudeInstructionsSection: View {
    @ObservedObject private var instructions = ClaudeInstructionStore.shared
    let openEditor: () -> Void
    var body: some View {
        GroupBox {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Claude 代码引用", systemImage: "text.badge.checkmark").font(.headline)
                    Text("让 Claude 输出易读、可定位的代码链接。规则可随时编辑。")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(instructions.status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("安装 / 编辑规则…", action: openEditor)
            }.padding(8)
        }.onAppear { instructions.refreshIfClean() }
    }
}

struct ClaudeInstructionsView: View {
    @ObservedObject private var instructions = ClaudeInstructionStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Claude Code 全局引用规则").font(.title2.bold())
                    Text("适用于所有代码项目；写入 ~/.claude/CLAUDE.md。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(instructions.status).font(.caption).foregroundStyle(.secondary)
            }
            Text("只管理下面这段规则，保留文件中的其他指令。保存或移除前会备份原文件。")
                .font(.caption).foregroundStyle(.secondary)
            if instructions.snapshot?.isLegacyStandalone == true {
                Text("已读取之前添加的完整规则。可直接编辑，或使用更短的推荐规则后保存。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $instructions.draft)
                .font(.system(.body, design: .monospaced))
                .padding(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
                .accessibilityLabel("Claude 全局代码引用规则")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text("\(instructions.draft.count) 字符\(instructions.dirty ? " · 尚未保存" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("恢复推荐规则") { instructions.useRecommended() }
                Button(instructions.dirty ? "放弃编辑并重新读取" : "重新读取文件") { instructions.reload() }
            }
            if let error = instructions.error {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled)
            }
            if let message = instructions.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("查看文件") { instructions.revealFile() }.disabled(instructions.snapshot?.exists != true)
                if instructions.lastBackup != nil { Button("查看备份") { instructions.revealBackup() } }
                Spacer()
                Button("移除这段规则") { instructions.remove() }.disabled(!instructions.installed)
                Button(instructions.installed ? "保存规则" : "安装规则") { instructions.save() }
                    .buttonStyle(.borderedProminent).disabled(!instructions.canSave)
                    .keyboardShortcut("s", modifiers: .command)
            }
        }.padding(20).frame(minWidth: 560, minHeight: 440)
    }
}
