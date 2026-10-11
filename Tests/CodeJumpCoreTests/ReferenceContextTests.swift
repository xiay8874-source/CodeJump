import Testing
@testable import CodeJumpCore

struct ReferenceContextTests {
    private let target = CodeReference(source: "file:///repo/src/Foo.java", path: "/repo/src/Foo.java", projectHint: "project-a", revision: "abc123")

    @Test func supplementsFilenamePositionAndPreservesTargetMetadata() {
        let result = ReferenceContext.enrich(target, labels: ["Foo.java:128:8"])
        #expect(result.line == 128)
        #expect(result.column == 8)
        #expect(result.path == target.path)
        #expect(result.source == target.source)
        #expect(result.projectHint == "project-a")
        #expect(result.revision == "abc123")
    }

    @Test func supplementsClassMethodAndRange() {
        let result = ReferenceContext.enrich(target, labels: ["Foo.createOrder（28-33行）"])
        #expect(result.line == 28)
        #expect(result.endLine == 33)
        #expect(result.symbol == "Foo.createOrder")
        #expect(ReferenceContext.enrich(target, labels: ["Foo#createOrder"]).symbol == "Foo#createOrder")
    }

    @Test func supportsTitleWithoutFileExtension() {
        let result = ReferenceContext.enrich(target, labels: ["Foo:246-251"])
        #expect(result.line == 246)
        #expect(result.endLine == 251)
        #expect(result.symbol == nil)
    }

    @Test func existingTargetPositionAndSymbolWin() {
        var located = target
        located.line = 90
        located.column = 2
        located.symbol = "Foo.otherMethod"
        var conflicting = located
        conflicting.contextAmbiguous = true
        #expect(ReferenceContext.enrich(located, labels: ["Foo.createOrder（28-33行）"]) == conflicting)
        #expect(ReferenceContext.enrich(located, labels: ["Foo.java:90:8"]) == conflicting)
        #expect(ReferenceContext.enrich(located, labels: ["Bar.java:90"]) == located)
    }

    @Test func canFillColumnOnMatchingExistingLine() {
        var located = target
        located.line = 90
        let result = ReferenceContext.enrich(located, labels: ["Foo.java:90:8"])
        #expect(result.line == 90)
        #expect(result.column == 8)
    }

    @Test func rejectsDifferentFilesClassesAndExplicitPaths() {
        for label in ["Bar.java:128", "Bar.createOrder（28-33行）", "Foo.kt:128", "/other/src/Foo.java:128", "other/Foo.java:128"] {
            #expect(ReferenceContext.enrich(target, labels: [label]) == target, Comment(rawValue: label))
        }
        #expect(ReferenceContext.enrich(target, labels: ["src/Foo.java:128"]).line == 128)
    }

    @Test func conflictsDoNotMerge() {
        var ambiguous = target
        ambiguous.contextAmbiguous = true
        #expect(ReferenceContext.enrich(target, labels: ["Foo.java:12", "Foo.java:13"]) == ambiguous)
        #expect(ReferenceContext.enrich(target, labels: ["Foo.first（12行）", "Foo.second（12行）"]) == ambiguous)
        #expect(ReferenceContext.enrich(target, labels: ["Foo.java:12-15", "Foo.java:12-20"]) == ambiguous)
        let complementary = ReferenceContext.enrich(target, labels: ["Foo.java:12", "Foo.first"])
        #expect(complementary.line == nil)
        #expect(complementary.symbol == "Foo.first")
        #expect(complementary.contextAmbiguous)
    }

    @Test func repeatedEquivalentLabelsAndIrrelevantLabelsAreFine() {
        let result = ReferenceContext.enrich(target, labels: ["Foo.java", "Foo.java:12", "Foo:12", "Bar.java:999", "not a reference"])
        #expect(result.line == 12)
        let method = ReferenceContext.enrich(target, labels: ["Foo.first（12行）", "Foo#first（12行）"])
        #expect(method.line == 12)
        #expect(method.symbol == "Foo#first")
    }

    @Test func refusesMissingPathOrUnboundedContext() {
        let noPath = CodeReference(source: "Foo", symbol: "Foo")
        #expect(ReferenceContext.enrich(noPath, labels: ["Foo.java:12"]) == noPath)
        #expect(ReferenceContext.enrich(target, labels: Array(repeating: "Foo.java:12", count: 33)) == target)
        #expect(ReferenceContext.enrich(target, labels: [String(repeating: "x", count: 5000) + " Foo.java:12"]) == target)
    }

    @Test func metadataCannotBeSilentlyLostWhenBorrowingHistoricalLocations() {
        let workingTree = CodeReference(source: "file", path: "/repo/src/Foo.java")
        #expect(ReferenceContext.enrich(workingTree, labels: ["repo@abc123:src/Foo.java:12"]) == workingTree)
        #expect(ReferenceContext.enrich(workingTree, labels: ["other-project / Foo.java:12"]) == workingTree)
        #expect(ReferenceContext.enrich(workingTree, labels: ["repo / Foo.java:12"]).line == 12)
    }

    @Test func staleTitleLineRetainsUniqueMethodForResolverValidation() {
        var located = target
        located.line = 90
        let result = ReferenceContext.enrich(located, labels: ["Foo.createOrder（28-33行）"])
        #expect(result.line == 90)
        #expect(result.endLine == nil)
        #expect(result.symbol == "Foo.createOrder")
        #expect(result.contextAmbiguous)
        #expect(result.projectHint == located.projectHint)
        #expect(result.revision == located.revision)
    }

    @Test func conflictingMethodLabelsNeverChooseASymbol() {
        var located = target
        located.line = 90
        let result = ReferenceContext.enrich(located, labels: ["Foo.first（28行）", "Foo.second（33行）"])
        #expect(result.line == 90)
        #expect(result.symbol == nil)
        #expect(result.contextAmbiguous)
        let sameMethod = ReferenceContext.enrich(target, labels: ["Foo.first（28行）", "Foo.first（33行）"])
        #expect(sameMethod.line == nil)
        #expect(sameMethod.symbol == "Foo.first")
        #expect(sameMethod.contextAmbiguous)
        var symbolOnly = target
        symbolOnly.symbol = "Foo.first"
        let differentMethods = ReferenceContext.enrich(symbolOnly, labels: ["Foo.first（12行）", "Foo.second（33行）"])
        #expect(differentMethods.line == nil)
        #expect(differentMethods.symbol == "Foo.first")
        #expect(differentMethods.contextAmbiguous)
    }

    @Test func existingAmbiguityIsPreservedAfterSuccessfulSupplement() {
        var ambiguous = target
        ambiguous.contextAmbiguous = true
        let result = ReferenceContext.enrich(ambiguous, labels: ["Foo.java:12"])
        #expect(result.line == 12)
        #expect(result.contextAmbiguous)
    }

    @Test func conflictingProjectOrRevisionDoesNotSupplement() {
        #expect(ReferenceContext.enrich(target, labels: ["project-b / Foo.java:12"]) == target)
        #expect(ReferenceContext.enrich(target, labels: ["project-a@def456:src/Foo.java:12"]) == target)
        #expect(ReferenceContext.enrich(target, labels: ["project-a@abc123:src/Foo.java:12"]).line == 12)
    }

    @Test func renderedRelativeURLCanUseItsVisibleProjectLabel() {
        let relative = CodeReference(source: "src/Foo.java:12", path: "src/Foo.java", line: 12)
        let result = ReferenceContext.enrich(relative, labels: ["demo-beta / Foo#send"])
        #expect(result.path == relative.path)
        #expect(result.line == 12)
        #expect(result.symbol == "Foo#send")
        #expect(result.projectHint == "demo-beta")
        #expect(!result.contextAmbiguous)
        let classOnly = ReferenceContext.enrich(relative, labels: ["demo-beta / Foo"])
        #expect(classOnly.projectHint == "demo-beta")
        #expect(classOnly.symbol == nil)
    }

    @Test func conflictingRenderedProjectLabelsRequireConfirmation() {
        let relative = CodeReference(source: "src/Foo.java", path: "src/Foo.java")
        let result = ReferenceContext.enrich(relative, labels: ["demo-alpha / Foo#send", "demo-beta / Foo#send"])
        #expect(result.projectHint == nil)
        #expect(result.contextAmbiguous)
    }

    @Test func renderedLabelsCannotMineRejectedLinksOrOverrideExplicitProject() {
        #expect(ReferenceContext.enrich(target, labels: ["[project-a / Foo#send](https://example.com/Foo.java)"]) == target)
        #expect(ReferenceContext.enrich(target, labels: ["project-b / Foo#send"]) == target)
        let conflictingFile = ReferenceContext.enrich(target, labels: ["[project-a / Bar#send](other/Bar.java:12)"])
        #expect(conflictingFile == target)
    }

    @Test func ownLinkTitleContradictionsRequireConfirmationWithoutReplacingTarget() {
        var expected = target
        expected.contextAmbiguous = true
        for label in ["project-b / Foo#send", "Bar#send", "other/Foo.java:12", "project-a@def456:src/Foo.java:12"] {
            #expect(ReferenceContext.enrich(target, labels: [label], labelsAreLinkTitles: true) == expected,
                    Comment(rawValue: label))
        }
        #expect(ReferenceContext.enrich(target, labels: ["[Foo#send](https://example.com/Foo.java)"], labelsAreLinkTitles: true) == target)
        #expect(ReferenceContext.enrich(target, labels: ["source"], labelsAreLinkTitles: true) == target)
        #expect(ReferenceContext.enrich(target, labels: ["[Bar#send](src/Foo.java:12)"], labelsAreLinkTitles: true) == expected)
    }
}
