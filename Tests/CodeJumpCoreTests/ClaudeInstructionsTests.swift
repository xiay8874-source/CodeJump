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
        #expect(Data(original.utf8).count == 2830)
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
