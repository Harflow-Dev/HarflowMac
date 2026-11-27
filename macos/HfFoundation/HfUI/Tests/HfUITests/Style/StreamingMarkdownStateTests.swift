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

    // MARK: - Nested lists

    private static let nestedFixture = "Intro\n\n1. First\n  - two\n    - four\n        - eight\n\t- tab\n   - three\n - one\n- top\n"
        + "plain\n  - orphan\n\n```\n  - code\n```\n- after fence\n  - child\n"

    private static func depths(_ state: StreamingMarkdownState) -> [Int] {
        state.blocks.compactMap { block in
            switch block.content {
            case .bullet(_, let depth), .numbered(_, _, let depth): depth
            default: nil
            }
        }
    }

    private static func prefixes(of text: String) -> [String] {
        let bytes = Array(text.utf8)
        return (1 ..< bytes.count).compactMap { String(bytes: bytes[..<$0], encoding: .utf8) }
    }

    @Test(arguments: [false, true])
    func givenNestedListSplitAtEveryUTF8Boundary_whenStreaming_thenEveryPrefixMatchesAFreshParse(crlf: Bool) {
        // given
        let text = crlf ? Self.nestedFixture.replacingOccurrences(of: "\n", with: "\r\n") : Self.nestedFixture
        var state = StreamingMarkdownState()

        // when / then
        for prefix in Self.prefixes(of: text) {
            state = state.updating(text: prefix, isStreaming: true)
            let fresh = StreamingMarkdownState().updating(text: prefix, isStreaming: true)
            #expect(state.blocks == fresh.blocks, "streaming prefix \(prefix.debugDescription)")
        }
        state = state.updating(text: text, isStreaming: true)
        #expect(state.blocks == StreamingMarkdownState().updating(text: text, isStreaming: true).blocks)
    }

    @Test(arguments: [false, true])
    func givenNestedListPrefixes_whenFinalising_thenMatchesAFreshFinalParse(crlf: Bool) {
        // given
        let text = crlf ? Self.nestedFixture.replacingOccurrences(of: "\n", with: "\r\n") : Self.nestedFixture
        var streaming = StreamingMarkdownState()

        // when / then
        for prefix in Self.prefixes(of: text) {
            streaming = streaming.updating(text: prefix, isStreaming: true)
            let finalised = streaming.updating(text: prefix + "\n", isStreaming: false)
            let fresh = StreamingMarkdownState().updating(text: prefix + "\n", isStreaming: false)
            #expect(finalised.blocks == fresh.blocks, "finalised prefix \(prefix.debugDescription)")
        }
    }

    @Test func givenNestedFixture_whenStreaming_thenDepthsMatchTheExpectedSequence() {
        // given / when
        let state = StreamingMarkdownState().updating(text: Self.nestedFixture, isStreaming: false)

        // then
        #expect(Self.depths(state) == [0, 1, 2, 3, 2, 1, 0, 0, 0, 0, 1])
    }

    @Test func givenIndentationArrivingInSeparateDeltas_whenStreaming_thenEarlierItemsKeepTheirDepth() {
        // given
        let deltas = ["1. a\n", " ", " ", "- b", "\n", "    ", "- c\n"]
        var state = StreamingMarkdownState()
        var seen: [Int: Int] = [:]
        var text = ""

        // when
        for delta in deltas {
            text += delta
            state = state.updating(text: text, isStreaming: true)
            for block in state.blocks {
                switch block.content {
                case .bullet(_, let depth), .numbered(_, _, let depth):
                    if let earlier = seen[block.id] { #expect(earlier == depth) }
                    seen[block.id] = depth
                default: break
                }
            }
        }

        // then
        #expect(Self.depths(state) == [0, 1, 2])
    }

    @Test func givenSealedNestedPrefix_whenDeeperItemArrives_thenDepthUsesCarriedNestingWithoutReparsingPrefix() {
        // given
        let prefix = "1. a\n  - b\n"
        let sealed = StreamingMarkdownState().updating(text: prefix, isStreaming: true)
        let suffix = "    - c\n"

        // when
        let state = sealed.updating(text: prefix + suffix, isStreaming: true)

        // then
        #expect(state.reparsedUTF8Count == suffix.utf8.count)
        #expect(Self.depths(state) == [0, 1, 2])
    }

    @Test func givenCorrectionThatChangesThePrefix_whenFinalTextArrives_thenNestingIsRebuiltFromZero() {
        // given
        let streaming = StreamingMarkdownState().updating(text: "- a\n  - b\n", isStreaming: true)

        // when
        let corrected = streaming.updating(text: "- x\n    - y\n", isStreaming: false)

        // then
        #expect(Self.depths(corrected) == [0, 1])
        #expect(corrected.blocks == StreamingMarkdownState().updating(text: "- x\n    - y\n", isStreaming: false).blocks)
    }

    @Test func givenSameTextDifferingOnlyInIndentation_whenPrepared_thenBlocksAreUnequal() {
        // given / when
        let flat = StreamingMarkdownState().updating(text: "- a\n- b", isStreaming: false)
        let nested = StreamingMarkdownState().updating(text: "- a\n  - b", isStreaming: false)

        // then
        #expect(flat != nested)
        #expect(Self.depths(flat) == [0, 0])
        #expect(Self.depths(nested) == [0, 1])
    }

    @Test func givenFlatListsAndExistingFixture_whenStreaming_thenEveryListDepthIsZero() {
        // given
        let text = "Intro **bold**\n\n- one\n- two\n\n1. three\n2) four\n\n```swift\nlet value = true\n```\n\n| Name | Value |\n|---|---|\n| status | ok |"

        // when
        let state = StreamingMarkdownState().updating(text: text, isStreaming: false)

        // then
        #expect(Self.depths(state) == [0, 0, 0, 0])
    }

    @Test(arguments: [false, true])
    func givenNestedFixture_whenParsedByBothParsers_thenListDepthsAgree(crlf: Bool) {
        // given
        let text = crlf ? Self.nestedFixture.replacingOccurrences(of: "\n", with: "\r\n") : Self.nestedFixture

        // when
        let viewDepths = MarkdownText.blocks(text).compactMap { block -> Int? in
            switch block {
            case .bullet(_, let depth), .numbered(_, _, let depth): depth
            default: nil
            }
        }
        let streamed = StreamingMarkdownState().updating(text: text, isStreaming: false)

        // then
        #expect(viewDepths == Self.depths(streamed))
        #expect(!viewDepths.isEmpty)
    }

    @Test func givenTextEndingInCarriageReturnWithoutNewline_whenFinalised_thenMatchesTheViewParser() {
        // given
        let text = "- a\r\n  - b\r"

        // when
        let state = StreamingMarkdownState().updating(text: text, isStreaming: false)

        // then
        #expect(Self.depths(state) == [0, 1])
        #expect(MarkdownText.blocks(text) == [.bullet("a", depth: 0), .bullet("b", depth: 1)])
        if case .bullet(let value, _) = state.blocks[1].content {
            #expect(String(value.characters) == "b")
        } else {
            Issue.record("Expected a bullet")
        }
    }
}
