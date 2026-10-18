import Foundation
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

@Suite struct InitialPromptTests {
    typealias Fixture = ActivityFixture

    private func messageTexts(_ rows: [ActivityRow]) -> [String] {
        rows.compactMap { row in
            guard case .single(let single) = row, case .item(let item) = single.kind, case .message(let text, _) = item.body else { return nil }
            return text
        }
    }

    @Test func givenTaskStartedAndItsInitialMessage_whenBuilt_thenOnlyTheStartedRowRemains() {
        // given — a live-input run logs the prompt twice.
        let rows = [Fixture.started(0, prompt: "Fix it"), Fixture.message(1, "Fix it", source: "initial"), Fixture.text(2)]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(result.map(\.id) == ["t1#0", "t1#2"])
        #expect(messageTexts(result).isEmpty)
    }

    @Test func givenOnlyTaskStarted_whenBuilt_thenItIsKept() {
        // given
        let rows = [Fixture.started(0, prompt: "Fix it"), Fixture.text(1)]
        // when / then
        #expect(ActivityRowsBuilder.build(from: rows).map(\.id) == ["t1#0", "t1#1"])
    }

    @Test func givenOnlyAnInitialMessage_whenBuilt_thenItIsTheOneBubble() {
        // given — no started row to carry the prompt.
        let rows = [Fixture.message(0, "Fix it", source: "initial"), Fixture.text(1)]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(messageTexts(result) == ["Fix it"])
    }

    @Test func givenAnInitialMessageThatDiffersFromThePrompt_whenBuilt_thenItIsKept() {
        // given
        let rows = [Fixture.started(0, prompt: "Fix it"), Fixture.message(1, "Something else", source: "initial")]
        // when / then
        #expect(messageTexts(ActivityRowsBuilder.build(from: rows)) == ["Something else"])
    }

    @Test func givenAnInjectedMessageEqualToThePrompt_whenBuilt_thenItIsKept() {
        // given — the suppression is for source "initial" only.
        let rows = [Fixture.started(0, prompt: "Fix it"), Fixture.message(1, "Fix it", source: "initial"), Fixture.message(2, "Fix it", source: "injected")]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(result.map(\.id) == ["t1#0", "t1#2"])
        #expect(messageTexts(result) == ["Fix it"])
    }

    @Test func givenAnInitialMessageDuplicatedLaterInTheRun_whenBuilt_thenOnlyTheFirstIsSuppressed() {
        // given
        let rows = [
            Fixture.started(0, prompt: "Fix it"), Fixture.message(1, "Fix it", source: "initial"), Fixture.text(2),
            Fixture.message(3, "Fix it", source: "initial")
        ]
        // when / then
        #expect(ActivityRowsBuilder.build(from: rows).map(\.id) == ["t1#0", "t1#2", "t1#3"])
    }

    @Test func givenAFollowUpSeparatorAndItsInitialMessage_whenBuilt_thenTheSeparatorIsTheOnlyBubble() {
        // given — MonitorCore already drops a follow-up's own initial message and started row; the first
        // member's still-present initial message is what this builder drops.
        let rows = [
            Fixture.started(0, prompt: "Fix it"), Fixture.message(1, "Fix it", source: "initial"), Fixture.text(2),
            Fixture.separator("Also test it", task: "t2"), Fixture.text(1, task: "t2")
        ]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(result.map(\.id) == ["t1#0", "t1#2", "sep:t2", "t2#1"])
    }

    @Test func givenAFollowUpsInitialMessageWithNoFirstMemberRows_whenBuilt_thenNothingIsSuppressed() {
        // given — the conversation opens with a separator (the first member has no rows yet).
        let rows = [Fixture.separator("Also test it", task: "t2"), Fixture.message(1, "Also test it", source: "initial", task: "t2")]
        // when / then
        #expect(ActivityRowsBuilder.build(from: rows).count == 2)
    }

    @Test func givenAStartedRowOfASecondMember_whenBuilt_thenTheFirstMembersPromptIsTheOneUsed() {
        // given — only the first member's started prompt defines the initial bubble.
        let rows = [
            Fixture.started(0, prompt: "First"), Fixture.separator("Second", task: "t2"),
            Fixture.started(0, prompt: "Second", task: "t2"), Fixture.message(1, "Second", source: "initial", task: "t2")
        ]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then — the second member's message is not the first member's, so it is left alone here.
        #expect(messageTexts(result) == ["Second"])
    }
}
