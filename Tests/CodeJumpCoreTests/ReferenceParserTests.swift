import Testing
@testable import CodeJumpCore

struct ReferenceParserTests {
    @Test func testActualClaudeAndObsidianForms() throws {
        let text = """
        [OrderRecordEnricher.java:31](demo-alpha-core/src/main/java/com/example/OrderRecordEnricher.java:31)
        `BatchProcessRecordCommand:246-251`
        `demo-alpha-core/.../ability/InternalRecordAbility.java`
        `RecordAbility.enrichRecord`（28-33 行）
        [RecordMigrationHelper#compareRecordResults](/Users/developer/Projects/demo-beta/RecordMigrationHelper.java:242)
        """
        let refs = ReferenceParser.parse(text)
        #expect(refs.count == 5)
        #expect(refs[0].path == "demo-alpha-core/src/main/java/com/example/OrderRecordEnricher.java")
        #expect(refs[0].line == 31)
        #expect(refs[0].symbol == nil)
        #expect(refs[1].symbol == "BatchProcessRecordCommand")
        #expect(refs[1].line == 246)
        #expect(refs[1].endLine == 251)
        #expect(refs[2].path == "demo-alpha-core/.../ability/InternalRecordAbility.java")
        #expect(refs[3].symbol == "RecordAbility.enrichRecord")
        #expect(refs[3].line == 28)
        #expect(refs[3].endLine == 33)
        #expect(refs[4].symbol == "RecordMigrationHelper#compareRecordResults")
        #expect(refs[4].line == 242)
    }

    @Test func testLocationFormsAndUnicodeSpaces() throws {
        let samples: [(String, String, Int?, Int?, Int?)] = [
            ("/Users/me/My Project/订单 服务.java:12:8", "/Users/me/My Project/订单 服务.java", 12, nil, 8),
            ("~/Projects/Order.java#L12-L19", "~/Projects/Order.java", 12, 19, nil),
            ("src/My App/Order.swift:42", "src/My App/Order.swift", 42, nil, nil),
            ("`订单模块/订单.java:24-37`", "订单模块/订单.java", 24, 37, nil),
            ("Foo.java", "Foo.java", nil, nil, nil),
            ("[m](</Users/me/My (Project)/Foo.java:12>)", "/Users/me/My (Project)/Foo.java", 12, nil, nil)
        ]
        for (input, path, line, end, column) in samples {
            let refs = ReferenceParser.parse(input)
            #expect(refs.count == 1, Comment(rawValue: input))
            let ref = try #require(refs.first, Comment(rawValue: input))
            #expect(ref.path == path, Comment(rawValue: input))
            #expect(ref.line == line, Comment(rawValue: input))
            #expect(ref.endLine == end, Comment(rawValue: input))
            #expect(ref.column == column, Comment(rawValue: input))
        }
    }

    @Test func testLocalFileURLsAndCustomProtocol() throws {
        let file = try #require(ReferenceParser.parse("<file:///Users/me/My%20Project/Foo.java#L12>").first)
        #expect(file.path == "/Users/me/My Project/Foo.java")
        #expect(file.line == 12)
        let local = try #require(ReferenceParser.parse("file://localhost/Users/me/Foo.java:30").first)
        #expect(local.line == 30)
        let deep = try #require(ReferenceParser.parse("codejump://open?path=src%2FFoo.java&line=128&column=3&project=demo-alpha").first)
        #expect(deep.path == "src/Foo.java")
        #expect(deep.projectHint == "demo-alpha")
        #expect(deep.line == 128)
        #expect(deep.column == 3)
    }

    @Test func testKeepsCrossProjectAmbiguityAndDeduplicatesLinks() {
        let input = """
        demo-alpha / Foo.java:128
        demo-beta / Foo.java:128
        [Foo.java:128](src/Foo.java:128), `src/Foo.java:128`
        """
        let refs = ReferenceParser.parse(input)
        #expect(refs.count == 3)
        #expect(refs.map(\.projectHint) == ["demo-alpha", "demo-beta", nil])
    }

    @Test func testRevisionAndMethod() throws {
        let ref = try #require(ReferenceParser.parse("Gamma@abc1234:src/main/Foo.java:7-10/doWork").first)
        #expect(ref.path == "src/main/Foo.java")
        #expect(ref.projectHint == "Gamma")
        #expect(ref.revision == "abc1234")
        #expect(ref.line == 7)
        #expect(ref.endLine == 10)
        #expect(ref.symbol == "doWork")
    }

    @Test func testHashMethodAndInlineClass() throws {
        let refs = ReferenceParser.parse("`OrderService#createOrder`（10-12 行） 和 `BatchProcessRecordCommand`")
        #expect(refs.count == 2)
        #expect(refs[0].symbol == "OrderService#createOrder")
        #expect(refs[0].line == 10)
        #expect(refs[1].symbol == "BatchProcessRecordCommand")
    }

    @Test func testRejectsWebLinksSchemesAndNonlocalFilesWithoutMiningTheirTitles() {
        let inputs = [
            "[Foo.java:1](https://example.com/Foo.java:8080)",
            "https://example.com/src/Foo.java:8080",
            "file://server/Users/me/Foo.java:12",
            "codejump://delete?path=Foo.java&line=12",
            "codejump://open?path=Foo.java&line=0",
            "codejump://open?path=Foo.java&path=Bar.java",
            "codejump://open?path=Foo.java&column=2",
            "[Foo.java:1](javascript:alert(1))",
            "ERROR:503 port:8080 foo.bar:12 spring.config:10",
            "这是普通文本 Hello Configuration Success",
            "`MAX_RETRIES`"
        ]
        for input in inputs { #expect(ReferenceParser.parse(input).isEmpty, Comment(rawValue: input)) }
    }

    @Test func testInvalidPositionsAreRejectedRatherThanDowngradedToFiles() {
        for input in ["Foo.java:0", "Foo.java:4-2", "Foo.java:12:0", "Foo.java:999999999999", "Foo.java:3:bad", "Foo.java#L0"] {
            #expect(ReferenceParser.parse(input).isEmpty, Comment(rawValue: input))
        }
    }

    @Test func testEncodedControlCharactersAndOversizeInput() {
        for input in [
            "file:///tmp/Foo%0A.java:1",
            "file:///tmp/Foo%00.java:1",
            "codejump://open?path=Foo.java%0A%3Brm&line=1",
            "codejump://open?path=Foo.java&project=a%0Ab",
            String(repeating: "x", count: 65_536) + " Foo.java:12"
        ] { #expect(ReferenceParser.parse(input).isEmpty, Comment(rawValue: input)) }
    }

    @Test func testParagraphFindsAllReferencesAndDoesNotAbsorbProse() {
        let refs = ReferenceParser.parse("请检查 src/Foo.java:3，然后查看 Bar.java:7。还有 OrderService.createOrder（9-11 行）")
        #expect(refs.count == 3)
        #expect(refs.map(\.path) == ["src/Foo.java", "Bar.java", nil])
        #expect(refs.map(\.line) == [3, 7, 9])
        #expect(refs.last?.endLine == 11)
        #expect(ReferenceParser.parse("See src/Foo.java").first?.path == "src/Foo.java")
    }

    @Test func testOversizedLineDoesNotHideOtherReferences() {
        let refs = ReferenceParser.parse(String(repeating: "/a ", count: 2000) + "\nFoo.java:3")
        #expect(refs.count == 1)
        #expect(refs.first?.path == "Foo.java")
        let repeated = Array(repeating: "Foo.java:3", count: 200).joined(separator: "\n")
        #expect(ReferenceParser.parse(repeated + "\nBar.java:7").count == 2)
    }

    @Test func testConflictingURLPositionIsRejected() {
        #expect(ReferenceParser.parse("codejump://open?path=Foo.java%3A20-25&line=30").isEmpty)
    }

    @Test func testBareClassLabelsRequireAnExactContext() {
        #expect(ReferenceParser.parse("OrderService").first?.symbol == "OrderService")
        #expect(ReferenceParser.parse("APIClient").first?.symbol == "APIClient")
        #expect(ReferenceParser.parse("Hello").isEmpty)
        #expect(ReferenceParser.parse("请看看 OrderService 的作用").isEmpty)
        #expect(ReferenceParser.parseClassLabel("Foo")?.symbol == "Foo")
        #expect(ReferenceParser.parseClassLabel("foo") == nil)
        #expect(ReferenceParser.parseClassLabel("Foo.java") == nil)
        #expect(ReferenceParser.parseClassLabel("FOO_CONSTANT") == nil)
        #expect(ReferenceParser.parseClassLabel("Foo\nBar") == nil)
    }

    @Test func testCompoundFileNamesInProse() {
        let refs = ReferenceParser.parse("请查看 Foo.test.ts:12 和 src/App.module.css:9")
        #expect(refs.map(\.path) == ["Foo.test.ts", "src/App.module.css"])
        #expect(refs.map(\.line) == [12, 9])
    }

    @Test func testRepeatedReferencesStayBounded() {
        let input = (0..<400).map { "Foo\($0).java:\($0 + 1)" }.joined(separator: "\n")
        #expect(ReferenceParser.parse(input).count <= 128)
    }
}
