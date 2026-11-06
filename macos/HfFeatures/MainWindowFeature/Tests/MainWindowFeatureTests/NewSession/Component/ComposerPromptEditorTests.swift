import AppKit
@testable import MainWindowFeature
import Testing

// MARK: - ComposerPromptEditorTests

@MainActor @Suite struct ComposerPromptEditorTests {
    @Test func givenTwoPromptEditors_whenUndoOwnershipIsRead_thenEachHasAnIndependentManager() throws {
        // given
        _ = NSApplication.shared
        let first = ComposerPromptScrollView()
        let second = ComposerPromptScrollView()

        // when
        let firstUndo = try #require(first.promptTextView.undoManager)
        let secondUndo = try #require(second.promptTextView.undoManager)

        // then — locking one prompt must not clear another control's undo history.
        #expect(firstUndo !== secondUndo)
    }

    @Test func givenApprovedComposerMetrics_whenRead_thenFloorAndCapMatchTheDesign() {
        // given / when — the approved centered composer: 22 pt lines, 2 pt vertical insets, six-line cap.
        // then
        #expect(ComposerSizing.lineHeight == 22)
        #expect(ComposerSizing.verticalInset == 2)
        #expect(ComposerSizing.maximumLines == 6)
        #expect(ComposerSizing.lineFragmentPadding == 6)
        #expect(ComposerSizing.floorHeight == 26)
        #expect(ComposerSizing.capHeight == 136)
    }

    @Test(arguments: [(1, 26), (3, 70), (6, 136)])
    func givenExactDraftLines_whenMeasuredByRealTextKit_thenTheEditorFollowsTheLineGrid(draftLines: Int, expectedHeight: Int) {
        // given — a real editor whose TextKit layout renders the same width it measures.
        let prompt = makePrompt()
        setDraft(draft(lineCount: draftLines), on: prompt)

        // when
        let lines = prompt.measuredLines(width: 600)
        let height = prompt.frameHeight(width: 600)

        // then — floor 26 / three lines 70 / six lines 136, derived from actual line fragments.
        #expect(lines == draftLines)
        #expect(abs(height - CGFloat(expectedHeight)) < 0.5)
    }

    @Test func givenEmptyDraft_whenMeasuredByRealTextKit_thenTheEditorFloorsAtOneLine() {
        // given
        let prompt = makePrompt()

        // when — the same container width measurement that renders.
        let lines = prompt.measuredLines(width: 600)
        let height = prompt.frameHeight(width: 600)

        // then — an empty draft is exactly the one-line floor, never the reserved insertion line twice.
        #expect(prompt.promptTextView.string.isEmpty)
        #expect(lines == 1)
        #expect(abs(height - ComposerSizing.floorHeight) < 0.5)
    }

    @Test func givenOneLongSentence_whenNarrowedThenReexpanded_thenTheHeightFollowsRealSoftWrapping() {
        // given — one unwrapped sentence at the approved composer width.
        let prompt = makePrompt()
        setDraft("Center the composer group with the approved exact metrics", on: prompt)

        // when — narrowing forces real soft wrapping, then re-expanding restores one line.
        // then
        #expect(prompt.measuredLines(width: 700) == 1)
        #expect(abs(prompt.frameHeight(width: 700) - ComposerSizing.floorHeight) < 0.5)
        #expect(prompt.measuredLines(width: 60) > 1)
        #expect(prompt.frameHeight(width: 60) > ComposerSizing.floorHeight)
        #expect(prompt.frameHeight(width: 60) <= ComposerSizing.capHeight + 0.5)
        #expect(prompt.measuredLines(width: 700) == 1)
        #expect(abs(prompt.frameHeight(width: 700) - ComposerSizing.floorHeight) < 0.5)
    }

    @Test func givenTrailingNewlineDraft_whenMeasured_thenTheExtraInsertionLineCounts() {
        // given — the native caret line TextKit reserves after a trailing newline.
        let prompt = makePrompt()

        // when / then — two paragraphs measure two lines…
        setDraft("First line\nSecond line", on: prompt)
        #expect(prompt.measuredLines(width: 600) == 2)
        #expect(abs(prompt.frameHeight(width: 600) - 48) < 0.5)

        // …and the trailing newline's insertion line counts as a real third line.
        setDraft("First line\nSecond line\n", on: prompt)
        #expect(prompt.measuredLines(width: 600) == 3)
        #expect(abs(prompt.frameHeight(width: 600) - 70) < 0.5)
    }

    @Test func givenUnicodeDrafts_whenMeasured_thenTheLayoutCountsActualWrappedLines() {
        // given — CJK and emoji content with wide glyphs and variation sequences.
        let prompt = makePrompt()
        setDraft(String(repeating: "🚀", count: 5), on: prompt)

        // when / then — short emoji content takes the one-line floor.
        #expect(abs(prompt.frameHeight(width: 600) - ComposerSizing.floorHeight) < 0.5)

        // and — a long CJK run soft-wraps at a narrow width, counting real fragments.
        setDraft(String(repeating: "一", count: 30), on: prompt)
        #expect(prompt.measuredLines(width: 60) > 1)
        #expect(prompt.frameHeight(width: 60) > ComposerSizing.floorHeight)
    }

    // MARK: - Fixtures

    private func makePrompt() -> ComposerPromptScrollView {
        _ = NSApplication.shared
        return ComposerPromptScrollView()
    }

    private func setDraft(_ draft: String, on prompt: ComposerPromptScrollView) {
        prompt.promptTextView.string = draft
        prompt.reassertParagraphMetrics()
        prompt.layoutSubtreeIfNeeded()
    }

    private func draft(lineCount: Int) -> String {
        (1 ... lineCount).map { "Draft line \($0)" }.joined(separator: "\n")
    }
}
