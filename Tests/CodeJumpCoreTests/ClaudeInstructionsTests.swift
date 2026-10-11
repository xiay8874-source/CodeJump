import Foundation
import Testing
@testable import CodeJumpCore

struct ClaudeInstructionsTests {
    private let begin = "<!-- CodeJump:begin -->"
    private let end = "<!-- CodeJump:end -->"

    private func temporaryFile(_ contents: String? = nil, _ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodeJumpInstructions-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("CLAUDE.md")
        if let contents { try Data(contents.utf8).write(to: url) }
        try body(url)
    }

    @Test
    func firstInstallCreatesMissingParentAndManagedBlock() throws {
        try temporaryFile { initialURL in
            let url = initialURL.deletingLastPathComponent().appendingPathComponent(".claude/CLAUDE.md")
            let before = try ClaudeInstructions.read(at: url)
            #expect(!before.exists)
            #expect(before.writable)
            #expect(before.managedText == nil)
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
            #expect(try ClaudeInstructions.save(ClaudeInstructions.defaultText, at: url, expected: before) == nil)
            let after = try ClaudeInstructions.read(at: url)
            #expect(after.exists)
            #expect(after.managedText == ClaudeInstructions.defaultText)
            #expect(after.fullText == begin + "\n" + ClaudeInstructions.defaultText + "\n" + end + "\n")
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        }
    }

    @Test
    func appendPreservesEveryExistingByteAndMakesExactBackup() throws {
        let original = "\u{FEFF}# Other instructions\r\nKeep e\u{301} exact.\r\n末尾没有换行"
        try temporaryFile(original) { url in
            let backup = try #require(try ClaudeInstructions.save("New instructions", at: url, expected: ClaudeInstructions.read(at: url)))
            #expect(try Data(contentsOf: backup) == Data(original.utf8))
            #expect(backup.deletingLastPathComponent().lastPathComponent == "codejump-backups")
            let after = try Data(contentsOf: url)
            #expect(after == Data((original + "\n\n" + begin + "\nNew instructions\n" + end + "\n").utf8))
        }
    }

    @Test
    func updateAndRemovePreserveUnrelatedContentAndPermissions() throws {
        let prefix = "# Personal\r\nUse Chinese.  \r\n\r\n"
        let suffix = "\r\n\r\n# Other tools\r\nKeep these rules.\r\n"
        let original = prefix + begin + "\r\nOld rules\r\n" + end + suffix
        try temporaryFile(original) { url in
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: url.path)
            let before = try ClaudeInstructions.read(at: url)
            #expect(before.managedText == "Old rules")
            let backup = try #require(try ClaudeInstructions.save("New rules", at: url, expected: before))
            let updated = prefix + begin + "\nNew rules\n" + end + suffix
            #expect(try Data(contentsOf: url) == Data(updated.utf8))
            #expect(try Data(contentsOf: backup) == Data(original.utf8))
            for file in [url, backup] {
                #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o640)
            }
            let removalBackup = try #require(try ClaudeInstructions.remove(at: url, expected: ClaudeInstructions.read(at: url)))
            #expect(try Data(contentsOf: removalBackup) == Data(updated.utf8))
            #expect(try Data(contentsOf: url) == Data((prefix + suffix).utf8))
            #expect(try ClaudeInstructions.read(at: url).managedText == nil)
            #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o640)
        }
    }

    @Test
    func exactLegacyStandaloneMigratesWithoutDuplicatingOldInstructions() throws {
        let original = ClaudeInstructions.legacyStandaloneText
        #expect(Data(original.utf8).count == 2829)
        #expect(original.split(separator: "\n", omittingEmptySubsequences: false).count == 50)
        try temporaryFile(original) { url in
            let before = try ClaudeInstructions.read(at: url)
            #expect(before.isLegacyStandalone)
            #expect(before.managedText == original)
            let backup = try #require(try ClaudeInstructions.save(ClaudeInstructions.defaultText, at: url, expected: before))
            #expect(try Data(contentsOf: backup) == Data(original.utf8))
            let after = try ClaudeInstructions.read(at: url)
            #expect(!after.isLegacyStandalone)
            #expect(after.managedText == ClaudeInstructions.defaultText)
            #expect(!after.fullText.contains("## 4. 以已核实的源码为准"))
        }
    }

    @Test
    func legacyHeadingAndExtraRulesAreNeverReplacedAsLegacy() throws {
        for original in ["# 代码引用与编辑器定位规范\nKeep personal content.\n",
                         ClaudeInstructions.legacyStandaloneText + "\nAlso keep these instructions.\n"] {
            try temporaryFile(original) { url in
                let before = try ClaudeInstructions.read(at: url)
                #expect(!before.isLegacyStandalone)
                #expect(before.managedText == nil)
                #expect(try ClaudeInstructions.remove(at: url, expected: before) == nil)
                #expect(try Data(contentsOf: url) == Data(original.utf8))
                try ClaudeInstructions.save("New rules", at: url, expected: before)
                #expect(try Data(contentsOf: url).starts(with: Data(original.utf8)))
            }
        }
    }

    @Test
    func externalChangeBlocksSaveAndRemoval() throws {
        try temporaryFile(begin + "\nOriginal\n" + end + "\n") { url in
            let before = try ClaudeInstructions.read(at: url)
            let external = "# Changed elsewhere\n"
            try Data(external.utf8).write(to: url)
            #expect(throws: ClaudeInstructionError.changedOnDisk) {
                try ClaudeInstructions.save("Mine", at: url, expected: before)
            }
            #expect(throws: ClaudeInstructionError.changedOnDisk) {
                try ClaudeInstructions.remove(at: url, expected: before)
            }
            #expect(try Data(contentsOf: url) == Data(external.utf8))
        }
    }

    @Test
    func conflictCheckUsesBytesRatherThanUnicodeEquivalence() throws {
        try temporaryFile("é") { url in
            let before = try ClaudeInstructions.read(at: url)
            try Data("e\u{301}".utf8).write(to: url)
            #expect(before.fullText == "e\u{301}")
            #expect(throws: ClaudeInstructionError.changedOnDisk) {
                try ClaudeInstructions.save("Rules", at: url, expected: before)
            }
            #expect(try Data(contentsOf: url) == Data("e\u{301}".utf8))
        }
    }

    @Test
    func fileCreationAndDeletionAreConflicts() throws {
        try temporaryFile { url in
            let absent = try ClaudeInstructions.read(at: url)
            try Data().write(to: url)
            #expect(throws: ClaudeInstructionError.changedOnDisk) {
                try ClaudeInstructions.save("Rules", at: url, expected: absent)
            }
            let existing = try ClaudeInstructions.read(at: url)
            try FileManager.default.removeItem(at: url)
            #expect(throws: ClaudeInstructionError.changedOnDisk) {
                try ClaudeInstructions.save("Rules", at: url, expected: existing)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func malformedOrDuplicateMarkersRefuseReadAndMutation() throws {
        let malformed = [begin, end, end + "\n" + begin,
                         begin + "\nRules\n" + end + "\n" + begin + "\nRules\n" + end,
                         "Inline " + begin + "\nRules\n" + end,
                         begin + "\nRules\n" + end + " trailing content",
                         "<!-- CodeJump:begin --\nRules\n" + end,
                         begin + "\n<!-- CodeJump:unknown -->\n" + end]
        for original in malformed {
            try temporaryFile { url in
                let absent = try ClaudeInstructions.read(at: url)
                try Data(original.utf8).write(to: url)
                #expect(throws: ClaudeInstructionError.malformedMarkers) { try ClaudeInstructions.read(at: url) }
                #expect(throws: ClaudeInstructionError.malformedMarkers) {
                    try ClaudeInstructions.save("Rules", at: url, expected: absent)
                }
                #expect(throws: ClaudeInstructionError.malformedMarkers) {
                    try ClaudeInstructions.remove(at: url, expected: absent)
                }
                #expect(try Data(contentsOf: url) == Data(original.utf8))
            }
        }
    }

    @Test
    func rejectsExistingAndDanglingSymlinkTargets() throws {
        try temporaryFile { url in
            let absent = try ClaudeInstructions.read(at: url)
            let target = url.deletingLastPathComponent().appendingPathComponent("Other.md")
            try Data("Other rules".utf8).write(to: target)
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
            #expect(throws: ClaudeInstructionError.symbolicLink) { try ClaudeInstructions.read(at: url) }
            #expect(throws: ClaudeInstructionError.symbolicLink) {
                try ClaudeInstructions.save("Rules", at: url, expected: absent)
            }
            #expect(try Data(contentsOf: target) == Data("Other rules".utf8))
            try FileManager.default.removeItem(at: target)
            #expect(throws: ClaudeInstructionError.symbolicLink) { try ClaudeInstructions.read(at: url) }
        }
    }

    @Test
    func rejectsSymlinkBackupDirectoryWithoutChangingOriginal() throws {
        try temporaryFile("Keep me") { url in
            let before = try ClaudeInstructions.read(at: url)
            let directory = url.deletingLastPathComponent()
            let target = directory.appendingPathComponent("Other", isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("codejump-backups"),
                                                     withDestinationURL: target)
            #expect(throws: ClaudeInstructionError.symbolicLink) {
                try ClaudeInstructions.save("Rules", at: url, expected: before)
            }
            #expect(try Data(contentsOf: url) == Data("Keep me".utf8))
            #expect(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    @Test
    func unchangedSaveAndAbsentRemovalAreNoOps() throws {
        try temporaryFile(begin + "\nRules\n" + end + "\n") { url in
            let before = try ClaudeInstructions.read(at: url)
            #expect(try ClaudeInstructions.save("Rules", at: url, expected: before) == nil)
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("codejump-backups").path))
        }
        try temporaryFile { url in
            let before = try ClaudeInstructions.read(at: url)
            #expect(try ClaudeInstructions.remove(at: url, expected: before) == nil)
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test
    func validatesInputAndFileSizeWithoutWriting() throws {
        try temporaryFile { url in
            let before = try ClaudeInstructions.read(at: url)
            #expect(throws: ClaudeInstructionError.emptyInstructions) {
                try ClaudeInstructions.save(" \n ", at: url, expected: before)
            }
            #expect(throws: ClaudeInstructionError.reservedMarkers) {
                try ClaudeInstructions.save("Rules\n" + begin, at: url, expected: before)
            }
            #expect(throws: ClaudeInstructionError.tooLarge) {
                try ClaudeInstructions.save(String(repeating: "x", count: 1_048_577), at: url, expected: before)
            }
            #expect(!FileManager.default.fileExists(atPath: url.path))
            try Data([0xff, 0xfe]).write(to: url)
            #expect(throws: ClaudeInstructionError.invalidUTF8) { try ClaudeInstructions.read(at: url) }
            try Data(repeating: 0x61, count: 1_048_577).write(to: url)
            #expect(throws: ClaudeInstructionError.tooLarge) { try ClaudeInstructions.read(at: url) }
        }
    }

    @Test
    func directoriesAreNotTreatedAsInstructionFiles() throws {
        try temporaryFile { url in
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            #expect(throws: ClaudeInstructionError.notRegularFile) { try ClaudeInstructions.read(at: url) }
        }
    }
}

private extension ClaudeInstructions {
    static let legacyStandaloneText = """
    # 代码引用与编辑器定位规范

    当回答涉及真实代码、源码定位、业务实现或调用链时，遵循以下规范，便于通过 CodeJump 定位到本地编辑器。

    ## 1. 使用真实、完整的代码名称

    - 使用源码中实际存在的完整类名和方法名，不用简称或概念名称替代。
    - 例如使用 BatchCreateRecordEnricherManager，不简写为 EnricherManager。
    - 方法引用使用“类名#方法名”，避免单独输出没有所属类的裸方法名。
    - 存在同名类时补充包名；存在方法重载时补充已核实的参数类型。
    - 概念性名称、伪代码和假设实现必须明确标注。

    ## 2. 优先使用 Markdown 超链接

    - 同一项目内，可见标签写“完整类名#方法名”；引用类时省略方法名，不重复添加项目名。
    - 跨项目或存在项目归属歧义时，标签写“项目名 / 完整类名#方法名”。
    - 链接目标使用项目内完整相对路径，已核实行号时追加“:行号”。
    - 正文和链接目标均不使用本机绝对路径，不暴露用户名或机器目录。
    - 链接目标中的目录必须完整，不使用 ... 等省略写法。
    - 链接标签与目标必须对应同一个文件、类或方法。

    格式示例：

    ```markdown
    [完整类名#方法名](模块/src/main/java/包路径/完整类名.java:行号)
    [项目名 / 完整类名#方法名](模块/src/main/java/包路径/完整类名.java:行号)
    ```

    以上仅为格式示意，实际输出必须替换为已核实的名称、路径和行号。

    ## 3. 清晰表达调用链和项目归属

    - 同项目调用链不必在每个节点重复标注项目。
    - 跨项目调用链中，对跨项目节点标明所属项目，避免混淆调用方和被调用方。
    - 区分接口、实现类及不同项目中的同名类。
    - 优先使用逐项列表，或“代码链接 → 代码链接”表达调用链。
    - 中文解释和箭头放在引用外，不把整条调用链包进一个行内代码中。
    - 不确定项目归属时明确说明，不根据名称猜测。

    ## 4. 以已核实的源码为准

    - 不编造项目归属、路径、类名、方法名、参数类型或行号。
    - 修改代码后，引用行号前重新核对当前位置。
    - 不知道行号时可以省略行号，不必强行补齐。
    - 不知道准确路径时，使用行内代码形式的“完整类名#方法名”或完整类名，不编造链接；跨项目时补充必要的项目说明。
    - 仅凭文档、记忆或推测得出的代码引用，应标注“未核实源码”。
    - 引用历史版本时说明对应分支或提交，不把历史行号当成当前工作区位置。

    仅在涉及代码引用时应用这些规则。普通问答和纯概念说明保持自然、简洁，不添加无关的项目名、路径或代码引用。

    """
}
