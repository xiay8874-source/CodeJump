import Foundation
import Darwin
import Testing
@testable import CodeJumpCore

struct EditorLaunchPlanTests {
    private struct Fixture {
        let temporary: URL
        let root: URL
        let file: URL
        var canonicalRoot: String { canonicalPath(root) }
        var canonicalFile: String { canonicalPath(file) }
        private func canonicalPath(_ url: URL) -> String {
            let path = url.path.withCString { realpath($0, nil) }!
            defer { free(path) }
            return String(cString: path)
        }
        var candidate: JumpCandidate {
            JumpCandidate(project: ProjectRoot(name: "测试项目", path: canonicalRoot),
                          absolutePath: canonicalFile, relativePath: file.lastPathComponent, line: 42, column: 8)
        }
        init() throws {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CodeJump-launch-\(UUID())")
            root = temporary.appendingPathComponent("项目 $money `backtick` spaces")
            file = root.appendingPathComponent("中文 $file `literal` name.java")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("class Example {}\n".utf8).write(to: file)
        }
        func remove() { try? FileManager.default.removeItem(at: temporary) }
    }

    @Test func ideaOpensProjectBeforeLineAndPreservesLiteralPaths() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let arguments = try EditorLaunchPlan.makeArguments(candidate: fixture.candidate, editor: .idea)
        #expect(arguments == [fixture.canonicalRoot, "--line", "42", "--column", "7", fixture.canonicalFile])
    }

    @Test func absentLineDoesNotInventALocation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var candidate = fixture.candidate
        candidate.line = nil; candidate.column = nil
        for editor in EditorKind.allCases {
            #expect(try EditorLaunchPlan.makeArguments(candidate: candidate, editor: editor) == [fixture.canonicalRoot, fixture.canonicalFile])
        }
    }

    @Test func codeAndCursorSpecifyWorkspaceWithoutReusingUnrelatedWindow() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for editor in [EditorKind.vscode, .cursor] {
            #expect(try EditorLaunchPlan.makeArguments(candidate: fixture.candidate, editor: editor) == [fixture.canonicalRoot, "--goto", fixture.canonicalFile + ":42:8"])
        }
        #expect(try EditorLaunchPlan.makeArguments(candidate: fixture.candidate, editor: .zed) == [fixture.canonicalRoot, fixture.canonicalFile + ":42:8"])
    }

    @Test func lineOnlyAndFirstColumnAreCorrect() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var candidate = fixture.candidate
        candidate.column = nil
        #expect(try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .vscode).last == fixture.canonicalFile + ":42")
        candidate.column = 1
        #expect(try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea).contains("0"))
    }

    @Test func invalidLocationsAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        for (line, column) in [(0, 1), (-1, 1), (1, 0), (1, -1), (Int.max, 1), (1, Int.max)] {
            var candidate = fixture.candidate
            candidate.line = line; candidate.column = column
            #expect(throws: EditorLaunchError.invalidPosition) {
                try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea)
            }
        }
        var candidate = fixture.candidate
        candidate.line = nil
        #expect(throws: EditorLaunchError.invalidPosition) {
            try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea)
        }
    }

    @Test func changedSymlinkCannotEscapeImportedProject() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let candidate = fixture.candidate
        let outside = fixture.temporary.appendingPathComponent("Outside.java")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: outside)
        #expect(throws: EditorLaunchError.fileOutsideProject) {
            try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea)
        }
    }

    @Test func replacingImportedRootWithSymlinkCannotRedirectExistingCandidate() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let candidate = fixture.candidate
        #expect(try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea).last == candidate.absolutePath)

        let outside = fixture.temporary.appendingPathComponent("different-project")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("class Different {}\n".utf8).write(to: outside.appendingPathComponent(fixture.file.lastPathComponent))
        try FileManager.default.moveItem(at: fixture.root, to: fixture.temporary.appendingPathComponent("original-project"))
        try FileManager.default.createSymbolicLink(at: fixture.root, withDestinationURL: outside)

        for editor in EditorKind.allCases {
            #expect(throws: EditorLaunchError.projectRootChanged) {
                try EditorLaunchPlan.makeArguments(candidate: candidate, editor: editor)
            }
        }
    }

    @Test func similarlyPrefixedSiblingProjectIsNotInsideRoot() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let sibling = URL(fileURLWithPath: fixture.root.path + "-copy")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let siblingFile = sibling.appendingPathComponent("Example.java")
        try Data().write(to: siblingFile)
        var candidate = fixture.candidate
        candidate.absolutePath = siblingFile.path
        #expect(throws: EditorLaunchError.fileOutsideProject) {
            try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea)
        }
    }

    @Test func symlinkThenParentTraversalUsesFilesystemSemantics() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let outside = fixture.temporary.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("Example.java"))
        try Data().write(to: fixture.root.appendingPathComponent("Example.java"))
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("linked"), withDestinationURL: outside.appendingPathComponent("nested"))
        var candidate = fixture.candidate
        candidate.absolutePath = fixture.root.path + "/linked/../Example.java"
        #expect(throws: EditorLaunchError.fileOutsideProject) {
            try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea)
        }
    }

    @Test func missingFilesDirectoriesURLsAndRelativePathsAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        for path in [fixture.root.appendingPathComponent("missing.java").path, fixture.root.appendingPathComponent("nested").path] {
            var candidate = fixture.candidate; candidate.absolutePath = path
            #expect(throws: EditorLaunchError.self) { try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea) }
        }
        for path in ["../Example.java", "https://example.com/a.java", "file:///tmp/Example.java", "/tmp/a\0.java"] {
            var candidate = fixture.candidate; candidate.absolutePath = path
            #expect(throws: EditorLaunchError.invalidPath(path)) { try EditorLaunchPlan.makeArguments(candidate: candidate, editor: .idea) }
        }
    }

    @Test func executableDiscoverySupportsUserCEInstallAndExplicitApp() throws {
        let ce = "/Users/test/Applications/IntelliJ IDEA CE.app/Contents/MacOS/idea"
        #expect(try EditorLaunchPlan.resolveExecutable(editor: .idea, homeDirectory: "/Users/test", isExecutable: { $0 == ce }) == ce)
        let custom = "/Volumes/开发 Apps/My IDEA.app"
        #expect(try EditorLaunchPlan.resolveExecutable(editor: .idea, applicationPath: custom, isExecutable: { $0 == custom + "/Contents/MacOS/idea" }) == custom + "/Contents/MacOS/idea")
        #expect(throws: EditorLaunchError.editorNotFound(.idea)) {
            try EditorLaunchPlan.resolveExecutable(editor: .idea, applicationPath: custom, isExecutable: { $0 == "/Applications/IntelliJ IDEA.app/Contents/MacOS/idea" })
        }
        #expect(throws: EditorLaunchError.invalidApplicationPath) {
            try EditorLaunchPlan.resolveExecutable(editor: .idea, applicationPath: "/bin/sh", isExecutable: { _ in true })
        }
    }

    @Test func makeChecksCustomAppExecutableWithoutLaunchingIt() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let app = fixture.temporary.appendingPathComponent("自定义 $IDE `literal`.app")
        let binary = app.appendingPathComponent("Contents/MacOS/idea")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("this fixture must never be executed".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: binary.path)
        #expect(throws: EditorLaunchError.editorNotFound(.idea)) {
            try EditorLaunchPlan.make(candidate: fixture.candidate, editor: .idea, applicationPath: app.path)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let plan = try EditorLaunchPlan.make(candidate: fixture.candidate, editor: .idea, applicationPath: app.path)
        #expect(plan.executable == binary.path)
        #expect(plan.arguments.last == fixture.canonicalFile)
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.createDirectory(at: binary, withIntermediateDirectories: false)
        #expect(throws: EditorLaunchError.editorNotFound(.idea)) {
            try EditorLaunchPlan.make(candidate: fixture.candidate, editor: .idea, applicationPath: app.path)
        }
    }
}
