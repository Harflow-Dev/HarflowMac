import HfUI
import Testing

@Suite struct StreamingMarkdownStateTests {
    @Test func givenAppendOnlyText_whenUpdatingAcrossClosedParagraphs_thenSealedIDsRemainStable() {
        // given
        let first = "Introductory text.\n\n- first item"
        var state = StreamingMarkdownState().updating(text: first, isStreaming: true)
        let firstID = state.blocks.first?.id
        let firstBlock = state.blocks.first

        // when
        state = state.updating(text: first + "\n\nA trailing paragraph.", isStreaming: true)

        // then
        #expect(state.source == first + "\n\nA trailing paragraph.")
        #expect(state.blocks.first?.id == firstID)
        #expect(state.blocks.first == firstBlock)
        let unresolvedTail = "- first item"
        let appendedSuffix = "\n\nA trailing paragraph."
        #expect(state.reparsedUTF8Count <= unresolvedTail.utf8.count + appendedSuffix.utf8.count)
        #expect(state.reparsedUTF8Count < state.source.utf8.count)
        #expect(state.blocks.count >= 3)
    }

    @Test func givenEveryCharacterSplit_whenUpdatingAwkwardMarkdown_thenFinalBlocksAreComplete() {
        // given
        let text = "Intro **bold**\n\n- one\n- two\n\n```swift\nlet value = true\n```\n\n| Name | Value |\n|---|---|\n| status | ✅ |"
        var state = StreamingMarkdownState()
        var priorBlocks: [StreamingMarkdownBlock] = []

        // when
        let prefixes = text.indices.dropLast().map { String(text[...$0]) }
        for prefix in prefixes {
            state = state.updating(text: prefix, isStreaming: true)
            let stableCount = max(0, min(priorBlocks.count, state.blocks.count) - 1)
            #expect(Array(state.blocks.prefix(stableCount)) == Array(priorBlocks.prefix(stableCount)))
            priorBlocks = state.blocks
        }
        state = state.updating(text: text, isStreaming: false)

        // then
        #expect(state.source == text)
        #expect(state.blocks.contains { if case .table = $0.content { true } else { false } })
        #expect(state.blocks.contains { if case .code = $0.content { true } else { false } })
        #expect(state.blocks.allSatisfy { $0.id >= 0 && $0.id <= text.utf8.count })
        #expect(Set(state.blocks.map(\.id)).count == state.blocks.count)
        #expect(state.blocks.contains { if case .bullet = $0.content { true } else { false } })
    }

    @Test func givenAmbiguousPipeLookahead_whenLiteralSuffixArrives_thenMatchesFreshParse() {
        // given
        let partial = StreamingMarkdownState().updating(text: "Intro\n|", isStreaming: true)

        // when
        let continued = partial.updating(text: "Intro\n| literal", isStreaming: true)
        let fresh = StreamingMarkdownState().updating(text: "Intro\n| literal", isStreaming: true)

        // then
        #expect(continued.blocks == fresh.blocks)
    }

    @Test func givenPipeLookingLikeTable_whenLiteralSuffixArrives_thenMatchesFreshParse() {
        // given
        let partial = StreamingMarkdownState().updating(text: "Intro\n| name |", isStreaming: true)

        // when
        let continued = partial.updating(text: "Intro\n| name | literal\n", isStreaming: true)
        let fresh = StreamingMarkdownState().updating(text: "Intro\n| name | literal\n", isStreaming: true)

        // then
        #expect(continued.blocks == fresh.blocks)
    }

    @Test func givenAmbiguousRuleLookahead_whenInlineSuffixArrives_thenMatchesFreshParse() {
        // given
        let partial = StreamingMarkdownState().updating(text: "Intro\n***", isStreaming: true)

        // when
        let continued = partial.updating(text: "Intro\n***bold", isStreaming: true)
        let fresh = StreamingMarkdownState().updating(text: "Intro\n***bold", isStreaming: true)

        // then
        #expect(continued.blocks == fresh.blocks)
    }

    @Test func givenRuleLookingLikeEmphasis_whenWhitespaceSuffixArrives_thenMatchesFreshParse() {
        // given
        let partial = StreamingMarkdownState().updating(text: "Intro\n***", isStreaming: true)

        // when
        let continued = partial.updating(text: "Intro\n*** bold", isStreaming: true)
        let fresh = StreamingMarkdownState().updating(text: "Intro\n*** bold", isStreaming: true)

        // then
        #expect(continued.blocks == fresh.blocks)
    }

    @Test func givenCRLFAndUnicode_whenUpdatingFinalText_thenIDsUseUTF8Offsets() {
        // given
        let text = "😀 heading\r\n\r\n- café"

        // when
        let state = StreamingMarkdownState().updating(text: text, isStreaming: false)

        // then
        #expect(state.source == text)
        #expect(state.blocks.map(\.id) == [0, 16])
        #expect(state.reparsedUTF8Count == text.utf8.count)
    }

    @Test func givenSameSource_whenFinalStateArrives_thenPresentationIsRetainedExactly() {
        // given
        let text = "A stable paragraph.\n\n```\ncode\n"
        let streaming = StreamingMarkdownState().updating(text: text, isStreaming: true)

        // when
        let final = streaming.updating(text: text, isStreaming: false)

        // then
        #expect(final == streaming)
        #expect(final.blocks == streaming.blocks)
        #expect(final.reparsedUTF8Count == streaming.reparsedUTF8Count)
    }

    @Test func givenDifferentFinalSource_whenCorrectionArrives_thenStateRebuildsFromTheCorrection() {
        // given
        let streaming = StreamingMarkdownState().updating(text: "Before", isStreaming: true)

        // when
        let corrected = streaming.updating(text: "After", isStreaming: false)

        // then
        #expect(corrected.source == "After")
        #expect(corrected.blocks.count == 1)
        #expect(corrected.blocks.first?.id == 0)
        #expect(corrected != streaming)
    }

    @Test func givenTableHeaderWithoutSeparator_whenStreaming_thenItRemainsProvisionalParagraph() {
        // given / when
        let state = StreamingMarkdownState().updating(text: "| Name | Value |", isStreaming: true)

        // then
        #expect(state.blocks.count == 1)
        if case .paragraph = state.blocks[0].content {
            // expected provisional presentation
        } else {
            Issue.record("A table header without its separator must remain provisional prose")
        }
    }

    @Test func givenCorrectionWithStablePrefix_whenFinalTextArrives_thenPrefixBlockIsRetained() {
        // given
        let streaming = StreamingMarkdownState().updating(text: "Stable prefix.\n\nDraft", isStreaming: true)
        let prefix = streaming.blocks.first

        // when
        let corrected = streaming.updating(text: "Stable prefix.\n\nFinal answer.", isStreaming: false)

        // then
        #expect(corrected.blocks.first == prefix)
        #expect(corrected.blocks.first?.id == 0)
    }

    @Test func givenFinalWhitespaceFrontier_whenValueIsAppended_thenBlockStartsAtZero() {
        // given
        let whitespace = StreamingMarkdownState().updating(text: "  ", isStreaming: false)

        // when
        let value = whitespace.updating(text: "  value", isStreaming: false)

        // then
        #expect(value.source == "  value")
        #expect(value.blocks.first?.id == 0)
    }

    @Test func givenMalformedOpenFenceAndTable_whenFinalized_thenStateRemainsDeterministic() {
        // given
        let text = "```swift\nlet value = true\n\n| Name | Value |\n|---|---|\n| status | complete |"

        // when
        let first = StreamingMarkdownState().updating(text: text, isStreaming: false)
        let second = StreamingMarkdownState().updating(text: text, isStreaming: false)

        // then
        #expect(first == second)
        #expect(first.blocks.contains { if case .code = $0.content { true } else { false } })
    }

    @Test func givenDuplicateAndEmptyDeltas_whenUpdating_thenNoAdditionalWorkIsReported() {
        // given
        let empty = StreamingMarkdownState()
        let first = empty.updating(text: "", isStreaming: true)
        let populated = first.updating(text: "hello", isStreaming: true)

        // when
        let duplicate = populated.updating(text: "hello", isStreaming: true)

        // then
        #expect(first == empty)
        #expect(duplicate == populated)
        #expect(duplicate.reparsedUTF8Count == populated.reparsedUTF8Count)
    }
}
