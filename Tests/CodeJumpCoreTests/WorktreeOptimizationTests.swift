import Foundation
import Testing
@testable import CodeJumpCore

struct WorktreeOptimizationTests {
    private func candidate(_ project: ProjectRoot, _ path: String = "src/Foo.java") -> JumpCandidate {
        JumpCandidate(project: project, absolutePath: project.path + "/" + path, relativePath: path)
    }

    private func jump(_ candidate: JumpCandidate, at date: Date) -> RecentJump {
        var jump = RecentJump(candidate: candidate)
        jump.date = date
        return jump
    }

    @Test
    func recentWorktreeIsListedFirstAndProjectOrderIsStable() {
        let main = ProjectRoot(name: "bg-sheep", path: "/w/bg-sheep")
        let tree = ProjectRoot(name: "bg-sheep-f-x", path: "/w/bg-sheep-f-x")
        let other = ProjectRoot(name: "bg-eagle", path: "/w/bg-eagle")
        let resolved = [candidate(main), candidate(main, "src/Bar.java"), candidate(tree),
                        candidate(tree, "src/Bar.java"), candidate(other)]
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(CandidateOrdering.sorted(resolved, recentJumps: [], usage: [:]) == resolved)

        let jumps = [jump(candidate(tree), at: base), jump(candidate(main), at: base.addingTimeInterval(-60))]
        let ordered = CandidateOrdering.sorted(resolved, recentJumps: jumps, usage: [:])
        #expect(ordered.map(\.project.name) == ["bg-sheep-f-x", "bg-sheep-f-x", "bg-sheep", "bg-sheep", "bg-eagle"])
        #expect(ordered.first?.relativePath == "src/Foo.java")

        let usage = [main.id.uuidString: ProjectUsage(lastOpened: base.addingTimeInterval(30), selectionCount: 1)]
        #expect(CandidateOrdering.sorted(resolved, recentJumps: jumps, usage: usage).first?.project.id == main.id)
        #expect(CandidateOrdering.sorted(resolved, preferredProjectID: other.id, recentJumps: jumps,
                                         usage: usage).first?.project.id == other.id)
    }

    @Test
    func eventFilterJudgesExcludedFoldersInsideTheProjectOnly() {
        let roots = ["/tmp/work/build/app", "/tmp/work/.cache/tool"]
        #expect(!ProjectIndex.isIgnoredEvent("/tmp/work/build/app/src/Foo.java", roots: roots))
        #expect(!ProjectIndex.isIgnoredEvent("/tmp/work/.cache/tool/src/Foo.java", roots: roots))
        #expect(ProjectIndex.isIgnoredEvent("/tmp/work/build/app/target/Foo.class", roots: roots))
        #expect(ProjectIndex.isIgnoredEvent("/tmp/work/build/app/.git/HEAD", roots: roots))
        #expect(!ProjectIndex.isIgnoredEvent("/tmp/work/build/app", roots: roots))
        #expect(!ProjectIndex.isIgnoredEvent("/tmp/work/build", roots: roots))
        #expect(!ProjectIndex.isIgnoredEvent("/elsewhere/target/Foo.class", roots: roots))
    }

    @Test
    func absoluteReferenceIntoUnimportedWorktreeNamesItsRootWithoutFallingBack() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("codejump-hint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        func write(_ path: String) throws -> URL {
            let url = base.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "class Foo {}\n".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        _ = try write("bg-sheep/svc/src/Foo.java")
        let file = try write("bg-sheep-f-new/svc/src/Foo.java")
        let tree = base.appendingPathComponent("bg-sheep-f-new")
        try "gitdir: /elsewhere\n".write(to: tree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let main = ProjectRoot(name: "bg-sheep", path: canonicalPath(base.appendingPathComponent("bg-sheep").path))
        let reference = CodeReference(source: "", path: file.path, line: 1)

        let index = try ProjectIndex.build(projects: [main])
        #expect(CodeResolver(index: index).resolve(reference).isEmpty)
        #expect(ImportHint.missingProjectRoot(for: [reference], projects: [main]) == canonicalPath(tree.path))

        var imported = ProjectRoot(name: "bg-sheep-f-new", path: canonicalPath(tree.path))
        #expect(ImportHint.missingProjectRoot(for: [reference], projects: [main, imported]) == nil)
        imported.enabled = false
        #expect(ImportHint.missingProjectRoot(for: [reference], projects: [main, imported]) == canonicalPath(tree.path))
        #expect(ImportHint.missingProjectRoot(for: [CodeReference(source: "", path: "svc/src/Foo.java")], projects: []) == nil)
    }
}
