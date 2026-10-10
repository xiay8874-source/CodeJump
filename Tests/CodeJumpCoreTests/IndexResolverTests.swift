import Foundation
import Testing
@testable import CodeJumpCore

struct IndexResolverTests {
    private func workspace(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codejump-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @discardableResult
    private func write(_ path: String, in root: URL, _ content: String = "class Foo {}\n") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test
    func testMultipleProjectsAndStrictProjectHint() throws {
        try workspace { root in
            let a = root.appendingPathComponent("demo-alpha")
            let b = root.appendingPathComponent("demo-beta")
            try write("src/OrderService.java", in: a)
            try write("src/OrderService.java", in: b)
            let index = try ProjectIndex.build(projects: [
                ProjectRoot(name: "Alpha", path: a.path, aliases: ["alpha"]),
                ProjectRoot(name: "Beta", path: b.path, aliases: ["beta"])
            ])
            let resolver = CodeResolver(index: index)
            #expect(resolver.resolve(CodeReference(source: "", path: "OrderService.java")).count == 2)
            #expect(resolver.resolve(CodeReference(source: "", path: "OrderService", projectHint: "beta")).first?.project.name == "Beta")
            #expect(resolver.resolve(CodeReference(source: "", path: "OrderService", projectHint: "unknown")).count == 0)
            #expect(resolver.resolve(CodeReference(source: "", path: "demo-alpha/src/OrderService.java")).count == 1)
        }
    }

    @Test
    func testSuffixEllipsisAndModuleDisambiguation() throws {
        try workspace { root in
            try write("demo-alpha-core/src/main/java/com/acme/ability/InternalRecordAbility.java", in: root)
            try write("demo-alpha-service/src/main/java/com/acme/ability/InternalRecordAbility.java", in: root)
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "demo-alpha", path: root.path)]))
            #expect(resolver.resolve(CodeReference(source: "", path: "ability/InternalRecordAbility.java")).count == 2)
            #expect(resolver.resolve(CodeReference(source: "", path: "demo-alpha-core/.../ability/InternalRecordAbility.java")).count == 1)
            #expect(resolver.resolve(CodeReference(source: "", path: "demo-alpha-core/.../wrong/InternalRecordAbility.java")).count == 0)
            #expect(resolver.resolve(CodeReference(source: "", path: "ability/.../com/InternalRecordAbility.java")).count == 0)
            #expect(resolver.resolve(CodeReference(source: "", path: "../ability/InternalRecordAbility.java")).count == 0)
        }
    }

    @Test
    func testRepeatedSegmentsAndZeroDirectoryEllipsis() throws {
        try workspace { root in
            try write("src/a/src/ability/Foo.java", in: root)
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            #expect(resolver.resolve(CodeReference(source: "", path: "src/.../src/ability/Foo.java")).count == 1)
            #expect(resolver.resolve(CodeReference(source: "", path: "src/a/.../src/ability/Foo.java")).count == 1)
        }
    }

    @Test
    func testSkipsExcludedFoldersAndDirectoryAndFileSymlinks() throws {
        try workspace { root in
            let project = root.appendingPathComponent("project")
            let outside = try write("outside/Secret.java", in: root)
            let normal = try write("src/Foo.java", in: project)
            try write("node_modules/pkg/Foo.java", in: project)
            try write("target/classes/Generated.java", in: project)
            try write(".git/Hidden.java", in: project)
            try write("bin/main/Foo.class", in: project, "compiled artifact")
            try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: outside.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("Secret.java"), withDestinationURL: outside)
            let index = try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: project.path)])
            #expect(index.files.count == 1)
            #expect(index.files.first?.absolutePath == canonicalPath(normal.path))
            let resolver = CodeResolver(index: index)
            #expect(resolver.resolve(CodeReference(source: "", path: outside.path)).isEmpty)
            #expect(resolver.resolve(CodeReference(source: "", path: project.appendingPathComponent("escape/Secret.java").path)).isEmpty)
            #expect(resolver.resolve(CodeReference(source: "", path: normal.path)).count == 1)
        }
    }

    @Test
    func testCachedFileCannotEscapeThroughReplacementSymlink() throws {
        try workspace { root in
            let project = root.appendingPathComponent("project")
            let file = try write("src/Foo.java", in: project)
            let outside = try write("outside/Foo.java", in: root)
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: project.path)]))
            try FileManager.default.removeItem(at: file.deletingLastPathComponent())
            try FileManager.default.createSymbolicLink(at: file.deletingLastPathComponent(), withDestinationURL: outside.deletingLastPathComponent())
            #expect(resolver.resolve(CodeReference(source: "", path: "Foo.java")).isEmpty)
        }
    }

    @Test
    func testCachedProjectRootCannotBecomeAnExternalSymlink() throws {
        try workspace { root in
            let project = root.appendingPathComponent("project")
            try write("Foo.java", in: project)
            let outside = try write("outside/Foo.java", in: root)
            let index = try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: project.path)])
            let resolver = CodeResolver(index: index)
            try FileManager.default.removeItem(at: project)
            try FileManager.default.createSymbolicLink(at: project, withDestinationURL: outside.deletingLastPathComponent())
            #expect(resolver.resolve(CodeReference(source: "", path: "Foo.java")).isEmpty)
            #expect(try index.updating(paths: [project.path]).files.isEmpty)
        }
    }

    @Test
    func testIncrementalAddDeleteSubtreeAndUnrelatedProject() throws {
        try workspace { root in
            let a = root.appendingPathComponent("A")
            let b = root.appendingPathComponent("B")
            try write("src/Foo.java", in: a)
            try write("src/Other.java", in: b)
            var index = try ProjectIndex.build(projects: [ProjectRoot(name: "A", path: a.path), ProjectRoot(name: "B", path: b.path)])
            let added = try write("nested/deep/New.java", in: a)
            index = try index.updating(paths: [added.path, added.deletingLastPathComponent().path, a.appendingPathComponent("nested").path])
            #expect(index.files.count == 3)
            #expect(index.files.filter { $0.filename == "New.java" }.count == 1)
            // An unrelated project receives no event; its cached contents must remain untouched.
            try FileManager.default.removeItem(at: b)
            try FileManager.default.removeItem(at: a.appendingPathComponent("nested"))
            index = try index.updating(paths: [a.appendingPathComponent("nested").path])
            #expect(index.files.count == 2)
            #expect(index.files.contains { $0.filename == "Other.java" })
            index = try index.updating(paths: [b.path])
            #expect(index.files.count == 1)
            let encoded = try JSONEncoder().encode(index)
            let restored = try JSONDecoder().decode(ProjectIndex.self, from: encoded)
            #expect(CodeResolver(index: restored).resolve(CodeReference(source: "", symbol: "Foo")).count == 1)
        }
    }

    @Test
    func testDisabledProjectAndOutsideEvents() throws {
        try workspace { root in
            let file = try write("src/Foo.java", in: root)
            let project = ProjectRoot(name: "P", path: root.path, enabled: false)
            let index = try ProjectIndex.build(projects: [project])
            #expect(index.files.isEmpty)
            let crafted = ProjectIndex(projects: [project], files: [IndexedFile(projectID: project.id, absolutePath: file.path, relativePath: "src/Foo.java")])
            #expect(CodeResolver(index: crafted).resolve(CodeReference(source: "", path: file.path)).isEmpty)
            #expect(try index.updating(paths: ["/unrelated/New.java"]).files == index.files)
        }
    }

    @Test
    func testJavaDeclarationsIgnoreCommentsStringsAndCallsAndPreserveOverloads() throws {
        try workspace { root in
            let source = """
            class Foo {
              // void enrichRecord(int fake) {}
              String text = "void enrichRecord() {}";
              Object value = helper.enrichRecord();
              /* public void enrichRecord(boolean fake) {} */
              @Override
              public void enrichRecord() {
                enrichRecord(1);
              }
              public <T> T enrichRecord(int value) throws Exception {
                return null;
              }
            }
            """
            try write("src/Foo.java", in: root, source)
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let matches = resolver.resolve(CodeReference(source: "", symbol: "Foo#enrichRecord"))
            #expect(matches.map(\.line) == [7, 10])
            #expect(matches.allSatisfy { $0.requiresConfirmation })
            #expect(matches.allSatisfy { $0.reason.contains("重载") })
        }
    }

    @Test
    func testMissingJavaMethodNeverUsesInvocationOrFirstLine() throws {
        try workspace { root in
            try write("Foo.java", in: root, """
            class Foo {
              Object field = enrichRecord();
              void run() { enrichRecord(); }
              String x = "public void enrichRecord() {}";
            }
            """)
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let matches = resolver.resolve(CodeReference(source: "", symbol: "Foo.enrichRecord"))
            #expect(matches.count == 1)
            #expect(matches.first?.line == nil)
            #expect(matches.first?.requiresConfirmation == true)
        }
    }

    @Test
    func testJavaTextBlocksAnnotationsAndInterfaceDeclarations() throws {
        try workspace { root in
            let source = "class Foo {\n String text = \"\"\"\n public void target() {}\n \"\"\";\n @Anno(value = \"target()\")\n public java.util.List<String> target(\n final String input) { return null; }\n}\n"
            try write("Foo.java", in: root, source)
            try write("Bar.java", in: root, "interface Bar {\n <T> T target(T value);\n}")
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let matches = resolver.resolve(CodeReference(source: "", path: "Foo.java", symbol: "target"))
            #expect(matches.map(\.line) == [6])
            #expect(!(matches.first?.requiresConfirmation ?? true))
            #expect(resolver.resolve(CodeReference(source: "", symbol: "Bar.target")).map(\.line) == [2])
        }
    }

    @Test
    func testUnsupportedSymbolsAndHistoricalReferencesRequireConfirmation() throws {
        try workspace { root in
            try write("Foo.swift", in: root, "func run() {}\n")
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let unsupported = resolver.resolve(CodeReference(source: "", path: "Foo.swift", symbol: "run"))
            #expect(unsupported.first?.requiresConfirmation == true)
            #expect(unsupported.first?.line == nil)
            let historical = resolver.resolve(CodeReference(source: "", path: "Foo.swift", line: 1, revision: "abc123"))
            #expect(historical.first?.requiresConfirmation == true)
            #expect(historical.first?.reason.contains("当前工作区") == true)
            #expect(historical.first?.line == 1)
        }
    }

    @Test
    func testLineRangeAndColumnValidation() throws {
        try workspace { root in
            try write("Foo.java", in: root, "class Foo {\n void run() {}\n}")
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let good = resolver.resolve(CodeReference(source: "", path: "Foo.java", line: 2, endLine: 3, column: 2)).first
            #expect(good?.line == 2)
            #expect(!(good?.requiresConfirmation ?? true))
            for line in [0, -1, 4, 999] {
                let bad = resolver.resolve(CodeReference(source: "", path: "Foo.java", line: line)).first
                #expect(bad?.requiresConfirmation == true)
                #expect(bad?.line == nil)
            }
            let badEnd = resolver.resolve(CodeReference(source: "", path: "Foo.java", line: 2, endLine: 20)).first
            #expect(badEnd?.line == 2)
            #expect(badEnd?.requiresConfirmation == true)
            let badColumn = resolver.resolve(CodeReference(source: "", path: "Foo.java", line: 2, column: 100)).first
            #expect(badColumn?.line == 2)
            #expect(badColumn?.column == nil)
            #expect(badColumn?.requiresConfirmation == true)
        }
    }

    @Test
    func testBoundedSourceReading() throws {
        try workspace { root in
            try write("Foo.java", in: root, String(repeating: " ", count: CodeResolver.maximumSourceBytes + 1))
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let match = resolver.resolve(CodeReference(source: "", path: "Foo.java", line: 1)).first
            #expect(match?.requiresConfirmation == true)
            #expect(match?.line == nil)
            #expect(match?.reason.contains("2 MB") == true)
        }
    }

    @Test
    func testStaleMethodLinkDoesNotSilentlyUseAnInBoundsOldLine() throws {
        try workspace { root in
            let file = try write("Foo.java", in: root, """
            class Foo {
              void unrelated() {
                System.out.println("old location");
              }
              @Override
              public void target() {
                if (true) {
                  String braces = "}"; // { must not affect the range
                }
              }
            }
            """)
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let reference = try #require(ReferenceParser.parse("[Foo#target](\(file.path):3)").first)
            let candidate = try #require(resolver.resolve(reference).first)
            #expect(candidate.line == 6)
            #expect(candidate.requiresConfirmation)
            #expect(candidate.reason.contains("第 3 行"))
            #expect(candidate.reason.contains("声明第 6 行"))

            let body = try #require(resolver.resolve(CodeReference(source: "", path: "Foo.java", symbol: "target", line: 8)).first)
            #expect(body.line == 8)
            #expect(!body.requiresConfirmation)

            let annotation = try #require(resolver.resolve(CodeReference(source: "", path: "Foo.java", symbol: "target", line: 5)).first)
            #expect(annotation.line == 5)
            #expect(!annotation.requiresConfirmation)

            let pastBody = try #require(resolver.resolve(CodeReference(source: "", path: "Foo.java", symbol: "target", line: 8, endLine: 11)).first)
            #expect(pastBody.line == 6)
            #expect(pastBody.requiresConfirmation)
        }
    }

    @Test
    func testSymbolAndLineRemainConservativeForOverloadsAndMissingSymbols() throws {
        try workspace { root in
            try write("Foo.java", in: root, """
            class Foo {
              void target() {}
              void target(int value) {}
            }
            """)
            try write("Other.swift", in: root, "func target() {}\n")
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let overloads = resolver.resolve(CodeReference(source: "", path: "Foo.java", symbol: "target", line: 2))
            #expect(overloads.map(\.line) == [2, 3])
            #expect(overloads.allSatisfy { $0.requiresConfirmation })
            let missing = try #require(resolver.resolve(CodeReference(source: "", path: "Foo.java", symbol: "missing", line: 2)).first)
            #expect(missing.line == nil)
            #expect(missing.requiresConfirmation)
            let unsupported = try #require(resolver.resolve(CodeReference(source: "", path: "Other.swift", symbol: "target", line: 1)).first)
            #expect(unsupported.line == nil)
            #expect(unsupported.requiresConfirmation)
        }
    }

    @Test
    func testConflictingSymbolOwnerCannotAutomaticallyOpenAnotherClass() throws {
        try workspace { root in
            let file = try write("Foo.java", in: root, "class Foo {\n void target() {}\n}")
            let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
            let wrong = try #require(ReferenceParser.parse("[Other#target](\(file.path):2)").first)
            let candidate = try #require(resolver.resolve(wrong).first)
            #expect(candidate.line == 2)
            #expect(candidate.requiresConfirmation)
            #expect(candidate.reason.contains("引用类名 Other"))
            let correct = try #require(resolver.resolve(CodeReference(source: "", path: "Foo.java", symbol: "Foo.target", line: 2)).first)
            #expect(!correct.requiresConfirmation)
            let nested = try #require(resolver.resolve(CodeReference(source: "", path: "Foo.java", symbol: "Foo.Inner.target", line: 2)).first)
            #expect(nested.requiresConfirmation)
            #expect(nested.reason.contains("引用类名 Inner"))
        }
    }
}
