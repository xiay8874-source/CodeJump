import Foundation
import Testing
@testable import CodeJumpCore

struct AccuracyRegressionTests {
    @Test func methodParenthesesAndQualifiedNames() {
        for text in ["`Foo.createOrder()`", "com.acme.Foo.createOrder()", "见Foo.createOrder()这里"] {
            let refs = ReferenceParser.parse(text)
            #expect(refs.count == 1)
            #expect(refs.first?.symbol?.hasSuffix("Foo.createOrder") == true)
        }
        #expect(ReferenceParser.parse("Foo.java:128行").first?.line == 128)
        #expect(ReferenceParser.parse("`Foo.createOrder(String, int)`").first?.parameterSignature == "String, int")
    }

    @Test func utf16PointerChoosesOneOccurrenceAndPreservesDuplicates() throws {
        let text = "😀 请看 `Foo.first()` 与 `Foo.second()`，再看 `Foo.first()`"
        let located = ReferenceParser.parseLocated(text)
        #expect(located.count == 3)
        let offset = (text as NSString).range(of: "second").location
        let selected = ReferenceSelection.select(text: text, utf16Offset: offset)
        #expect(selected.count == 1)
        #expect(selected.first?.symbol == "Foo.second")
        #expect(selected.first?.isFallback == false)
        #expect(ReferenceSelection.select(text: text, utf16Offset: 0).allSatisfy { $0.isFallback })
        for item in located { #expect((text as NSString).substring(with: item.range).contains("Foo.")) }
    }

    @Test func ownerAnnotationsAndCacheEdits() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Foo.java")
        let source = """
        class Foo {
          @SuppressWarnings({"a", "b"})
          void target(@Tags({"x", "y"}) String x) {}
          class Inner {
            void target() {}
          }
        }
        """
        try source.write(to: file, atomically: true, encoding: .utf8)
        let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
        let outer = resolver.resolve(CodeReference(source: "", symbol: "Foo.target"))
        #expect(outer.count == 1)
        #expect(outer.first?.line == 3)
        #expect(outer.first?.requiresConfirmation == false)
        let inner = resolver.resolve(CodeReference(source: "", symbol: "Foo.Inner.target"))
        #expect(inner.count == 1)
        #expect(inner.first?.line == 5)
        #expect(inner.first?.requiresConfirmation == false)
        let history = RecentJump(candidate: try #require(inner.first))
        #expect(resolver.resolve(history.reference).first?.line == 5)
        try ("\n" + source).write(to: file, atomically: true, encoding: .utf8)
        #expect(resolver.resolve(CodeReference(source: "", symbol: "Foo.target")).first?.line == 4)
        let preview = try SourcePreview.read(try #require(resolver.resolve(CodeReference(source: "", symbol: "Foo.target")).first))
        #expect(preview.first(where: \.highlighted)?.number == 4)
    }

    @Test func innerOnlyMustNotMasqueradeAsOuterMethod() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "class Foo { class Inner { void target() {} } }".write(to: root.appendingPathComponent("Foo.java"), atomically: true, encoding: .utf8)
        let resolver = CodeResolver(index: try ProjectIndex.build(projects: [ProjectRoot(name: "P", path: root.path)]))
        let result = resolver.resolve(CodeReference(source: "", symbol: "Foo.target"))
        #expect(result.first?.line == nil)
        #expect(result.first?.requiresConfirmation == true)
    }

    @Test func historyAndFallbackAlwaysRequireConfirmation() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Foo.java")
        try "class Foo {\n void target() {}\n}".write(to: file, atomically: true, encoding: .utf8)
        let project = ProjectRoot(name: "P", path: root.path)
        let resolver = CodeResolver(index: try ProjectIndex.build(projects: [project]))
        let candidate = try #require(resolver.resolve(CodeReference(source: "", symbol: "Foo.target")).first)
        let recent = RecentJump(candidate: candidate)
        try "class Foo {\n\n void target() {}\n}".write(to: file, atomically: true, encoding: .utf8)
        let reopened = resolver.resolve(recent.reference)
        #expect(reopened.first?.line == 3)
        #expect(reopened.first?.requiresConfirmation == true)
        try FileManager.default.removeItem(at: file)
        #expect(resolver.resolve(recent.reference).isEmpty)
        #expect(throws: (any Error).self) { try SourcePreview.read(candidate) }
    }
}
