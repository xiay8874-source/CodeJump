import AppKit
import CodeJumpCore
import Combine
import Foundation

@MainActor final class ClaudeInstructionStore: ObservableObject {
    static let shared = ClaudeInstructionStore()
    @Published var draft = ClaudeInstructions.defaultText
    @Published private(set) var snapshot: ClaudeInstructionSnapshot?
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var lastBackup: URL?
    let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/CLAUDE.md")

    var installed: Bool { snapshot?.managedText != nil || snapshot?.isLegacyStandalone == true }
    var dirty: Bool { draft != (snapshot?.managedText ?? ClaudeInstructions.defaultText) }
    var canSave: Bool { snapshot?.writable == true && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var status: String {
        if snapshot == nil { return error == nil ? "尚未读取" : "暂时无法读取" }
        if snapshot?.isLegacyStandalone == true { return "检测到之前添加的规则" }
        return installed ? "已安装到 Claude Code" : "尚未安装"
    }

    func refreshIfClean() { if !dirty { reload() } }
    func reload() {
        do {
            let current = try ClaudeInstructions.read(at: fileURL)
            snapshot = current
            draft = current.managedText ?? ClaudeInstructions.defaultText
            error = nil; message = nil
        } catch { self.error = error.localizedDescription }
    }
    func useRecommended() { draft = ClaudeInstructions.defaultText; message = "推荐规则已填入，点击保存后生效。"; error = nil }
    func save() {
        guard let expected = snapshot, canSave else { return }
        do {
            let backup = try ClaudeInstructions.save(draft, at: fileURL, expected: expected)
            reload(); lastBackup = backup
            message = "已保存。新开的 Claude Code 会话会加载这段规则。"
        } catch { self.error = error.localizedDescription; message = nil }
    }
    func remove() {
        guard let expected = snapshot, installed else { return }
        do {
            let backup = try ClaudeInstructions.remove(at: fileURL, expected: expected)
            reload(); lastBackup = backup
            message = "已移除 CodeJump 规则，其他全局指令保持不变。"
        } catch { self.error = error.localizedDescription; message = nil }
    }
    func revealFile() { NSWorkspace.shared.activateFileViewerSelecting([fileURL]) }
    func revealBackup() { if let lastBackup { NSWorkspace.shared.activateFileViewerSelecting([lastBackup]) } }
}
