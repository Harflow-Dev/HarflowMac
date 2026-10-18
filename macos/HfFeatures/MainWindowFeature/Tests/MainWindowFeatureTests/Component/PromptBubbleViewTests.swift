@testable import MainWindowFeature
import Testing

// MARK: - PromptBubbleViewTests

@Suite struct PromptBubbleViewTests {

    @Test func givenAShortSingleLinePrompt_whenCheckingLength_thenItIsNotClamped() {
        // given
        let text = "Fix the flaky login test."

        // when
        let isLong = PromptBubbleView.isLong(text)

        // then
        #expect(!isLong)
    }

    @Test func givenAPromptPastTheCharacterLimit_whenCheckingLength_thenItIsClamped() {
        // given
        let text = String(repeating: "a", count: PromptBubbleView.collapsedCharacterLimit + 1)

        // when
        let isLong = PromptBubbleView.isLong(text)

        // then
        #expect(isLong)
    }

    @Test func givenAPromptAtTheCharacterLimit_whenCheckingLength_thenItIsNotClamped() {
        // given
        let text = String(repeating: "a", count: PromptBubbleView.collapsedCharacterLimit)

        // when
        let isLong = PromptBubbleView.isLong(text)

        // then
        #expect(!isLong)
    }

    @Test func givenAShortPromptWithManyLines_whenCheckingLength_thenItIsClamped() {
        // given
        let text = "one\ntwo\nthree\nfour"

        // when
        let isLong = PromptBubbleView.isLong(text)

        // then
        #expect(isLong)
    }
}
