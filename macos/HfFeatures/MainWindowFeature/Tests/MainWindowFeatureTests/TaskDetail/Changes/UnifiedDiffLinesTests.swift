import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - UnifiedDiffLinesTests

/// The hunk-aware classifier: position decides, so content that looks like a header is still content inside a hunk.
struct UnifiedDiffLinesTests {
    private typealias Line = UnifiedDiffLines.Line

    private func kinds(_ text: String) -> [UnifiedDiffLines.Kind] { UnifiedDiffLines.classify(text).map(\.kind) }

    @Test func givenASimplePatch_whenClassified_thenMetaPrecedesTheHunkAndSignsAreDropped() {
        // given
        let patch = "diff --git a/f b/f\nindex 111..222 100644\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n"

        // when
        let lines = UnifiedDiffLines.classify(patch)

        // then
        #expect(lines == [
            Line(kind: .meta, text: "diff --git a/f b/f"), Line(kind: .meta, text: "index 111..222 100644"),
            Line(kind: .meta, text: "--- a/f"), Line(kind: .meta, text: "+++ b/f"), Line(kind: .hunk, text: "@@ -1,2 +1,2 @@"),
            Line(kind: .context, text: "keep"), Line(kind: .removed, text: "old"), Line(kind: .added, text: "new")
        ])
    }

    @Test func givenContentLinesThatLookLikeHeaders_whenInsideAHunk_thenTheyAreRemovedAndAddedContent() {
        // given: a removed line "-- x" and an added line "++ x" print as "--- x" and "+++ x"
        let patch = "@@ -1 +1 @@\n--- x\n+++ x\n"

        // when
        let lines = UnifiedDiffLines.classify(patch)

        // then
        #expect(lines == [Line(kind: .hunk, text: "@@ -1 +1 @@"), Line(kind: .removed, text: "-- x"), Line(kind: .added, text: "++ x")])
    }

    @Test func givenTheSameLinesBeforeAnyHunk_whenClassified_thenTheyAreMeta() {
        // given / when / then
        #expect(kinds("--- a/f\n+++ b/f\n") == [.meta, .meta])
    }

    @Test func givenTheNoNewlineMarker_whenInsideAHunk_thenItIsKeptWhole() {
        // given
        let patch = "@@ -1 +1 @@\n-a\n\\ No newline at end of file\n+b\n\\ No newline at end of file\n"

        // when
        let lines = UnifiedDiffLines.classify(patch)

        // then
        #expect(lines.map(\.kind) == [.hunk, .removed, .noNewline, .added, .noNewline])
        #expect(lines[2].text == "\\ No newline at end of file")
    }

    @Test func givenSeveralHunks_whenClassified_thenEachAtSignLineStartsAHunk() {
        // given
        let patch = "@@ -1 +1 @@\n a\n@@ -9 +9 @@\n-b\n+c\n"
        // when / then
        #expect(kinds(patch) == [.hunk, .context, .hunk, .removed, .added])
    }

    @Test func givenATypeChangesTwoSections_whenClassified_thenTheSecondSectionsHeadersAreMeta() {
        // given
        let patch = """
        diff --git a/f b/f
        deleted file mode 120000
        --- a/f
        +++ /dev/null
        @@ -1 +0,0 @@
        -target
        \\ No newline at end of file
        diff --git a/f b/f
        new file mode 100644
        --- /dev/null
        +++ b/f
        @@ -0,0 +1 @@
        +text

        """

        // when
        let lines = UnifiedDiffLines.classify(patch)

        // then
        #expect(lines.map(\.kind) == [
            .meta, .meta, .meta, .meta, .hunk, .removed, .noNewline,
            .meta, .meta, .meta, .meta, .hunk, .added
        ])
        #expect(lines[10].text == "+++ b/f", "a header of the second section is not an added line")
        #expect(lines[9].text == "--- /dev/null")
    }

    @Test func givenAnEmptyLineInsideAHunk_whenClassified_thenItIsAnEmptyContextLine() {
        // given / when
        let lines = UnifiedDiffLines.classify("@@ -1,3 +1,3 @@\n a\n\n b\n")
        // then
        #expect(lines.map(\.kind) == [.hunk, .context, .context, .context])
        #expect(lines[2].text.isEmpty)
    }

    @Test func givenNoTrailingNewline_whenClassified_thenTheLastLineIsStillKept() {
        // given / when / then
        #expect(UnifiedDiffLines.classify("@@ -1 +1 @@\n+z").map(\.text) == ["@@ -1 +1 @@", "z"])
    }

    @Test func givenOneTrailingNewline_whenClassified_thenNoEmptyLineIsAdded() {
        // given / when / then
        #expect(UnifiedDiffLines.classify("a\n").count == 1)
        #expect(UnifiedDiffLines.classify("a\n\n").count == 2)
    }

    @Test func givenEmptyText_whenClassified_thenThereAreNoLines() {
        // given / when / then
        #expect(UnifiedDiffLines.classify("").isEmpty)
    }

    @Test func givenTextWithoutAHunk_whenClassified_thenEveryLineIsMeta() {
        // given / when / then
        #expect(kinds("hello\n+not added\n-not removed\n context-looking\n") == [.meta, .meta, .meta, .meta])
    }

    @Test func givenAnAtSignLineInsideAHunk_whenClassified_thenItStartsTheNextHunk() {
        // given / when / then
        #expect(kinds("@@ -1 +1 @@\n+a\n@@ -5 +5 @@\n+b\n") == [.hunk, .added, .hunk, .added])
    }

    @Test func givenCarriageReturnsAndTabs_whenClassified_thenTheyAreKeptInTheText() {
        // given / when
        let lines = UnifiedDiffLines.classify("@@ -1 +1 @@\n+a\tb\r\n")
        // then
        #expect(lines.last == Line(kind: .added, text: "a\tb", hadCarriageReturn: true))
    }

    @Test func givenCRLFLines_whenClassified_thenTheCarriageReturnIsRecordedAndRemovedFromTheText() {
        // given / when
        let lines = UnifiedDiffLines.classify("diff --git a/f b/f\r\n@@ -1 +1 @@\r\n-a\r\n+b\r\n c\r\n")
        // then
        #expect(lines.map(\.kind) == [.meta, .hunk, .removed, .added, .context])
        #expect(lines.map(\.text) == ["diff --git a/f b/f", "@@ -1 +1 @@", "a", "b", "c"])
        let marked = lines.map(\.hadCarriageReturn)
        #expect(marked == Array(repeating: true, count: 5))
    }

    @Test func givenMixedLineEndings_whenClassified_thenOnlyCarriageReturnLinesAreMarked() {
        // given / when
        let lines = UnifiedDiffLines.classify("@@ -1 +1 @@\n-a\r\n+b\n")
        // then
        #expect(lines.map(\.hadCarriageReturn) == [false, true, false])
    }

    @Test func givenABareCarriageReturnLineInAHunk_whenClassified_thenItIsAnEmptyContextLine() {
        // given / when
        let lines = UnifiedDiffLines.classify("@@ -1 +1 @@\n\r\n")
        // then
        #expect(lines.last == Line(kind: .context, text: "", hadCarriageReturn: true))
    }

    @Test(arguments: ["+", "-", " "])
    func givenAPrefixFollowedByACombiningMark_whenClassified_thenTheFirstScalarStillDecidesTheKind(prefix: String) {
        // given: grapheme-wise the prefix and the mark are one character, so only scalars see the prefix
        let lines = UnifiedDiffLines.classify("@@ -1 +1 @@\n" + prefix + "\u{301}x\n")
        // then
        let expected: UnifiedDiffLines.Kind = prefix == "+" ? .added : prefix == "-" ? .removed : .context
        #expect(lines.last == Line(kind: expected, text: "\u{301}x"))
    }

    @Test func givenALineDescription_whenPrinted_thenItNamesTheKindWithoutTheText() {
        // given
        let line = Line(kind: .added, text: "SECRET-TEXT")
        // when / then
        #expect(String(describing: line) == "UnifiedDiffLines.Line(added)")
        #expect(!String(reflecting: line).contains("SECRET"))
        #expect(!String(describing: [line]).contains("SECRET"))
    }
}
