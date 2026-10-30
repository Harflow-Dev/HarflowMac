import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - NeedsYouVMTests

@MainActor
@Suite struct NeedsYouVMTests {
    private struct Rig {
        let sut: NeedsYouVM
        let useCase: MockNeedsYouUseCase
        let routing: MockNeedsYouRouting
        let subject: CurrentValueSubject<NeedsYouSnapshot, Never>
        let routed: LockedRouted
    }

    final class LockedRouted: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String?] = []
        var all: [String?] { lock.withLock { values } }
        func add(_ value: String?) { lock.withLock { values.append(value) } }
    }

    private func item(_ id: String = "input:w1:d1", kind: NeedsYouItem.Kind = .question, ended: Bool = true) -> NeedsYouItem {
        NeedsYouItem(
            id: id, kind: kind, rootRunID: "w1", sourceRunID: "w1", runTitle: "Release", pathTitles: ["Release", "Choose"],
            text: "Which target?", ownership: .init(owner: ended ? "caller" : "monitor", callerEnded: ended, engineNote: "gone", handover: nil),
            startedBy: "Original caller", waitingSince: Date(timeIntervalSince1970: 100), decisionID: "d1"
        )
    }

    private func rig(
        items: [NeedsYouItem], phase: NeedsYouSnapshot.Phase = .ready, outcome: NeedsYouAnswerOutcome = .accepted, reduceMotion: Bool = true
    ) -> Rig {
        let useCase = MockNeedsYouUseCase()
        let routing = MockNeedsYouRouting()
        let subject = CurrentValueSubject<NeedsYouSnapshot, Never>(NeedsYouSnapshot(phase: phase, items: items))
        given(useCase).snapshot.willProduce { subject.value }
        given(useCase).snapshotPublisher().willReturn(subject.eraseToAnyPublisher())
        given(useCase).refresh().willReturn()
        given(useCase).answer(.any, text: .any, additionalAttempts: .any).willReturn(outcome)
        given(useCase).respond(.any, decision: .any).willReturn(outcome)
        let routed = LockedRouted()
        given(routing).showNeedsYou(itemID: .any).willProduce { routed.add($0) }
        let sut = NeedsYouVM(useCase: useCase, routing: routing)
        sut.didChangeReduceMotion(reduceMotion)
        return Rig(sut: sut, useCase: useCase, routing: routing, subject: subject, routed: routed)
    }

    @Test func givenSnapshot_whenAppeared_thenRowsAreMappedOffMain() async {
        // given
        let rig = rig(items: [item()])
        // when
        rig.sut.didAppear()
        await waitUntil { rig.sut.presentation.rows.count == 1 }
        // then
        #expect(rig.sut.presentation.rows.first?.title == "Release")
        #expect(rig.sut.presentation.summary == "1 request you can answer")
        verify(rig.useCase).refresh().called(1)
    }

    @Test func givenAppearedTwice_whenDisappeared_thenSubscribingIsIdempotentAndReleased() async {
        // given
        let rig = rig(items: [item()])
        rig.sut.didAppear()
        rig.sut.didAppear()
        // when
        rig.sut.didDisappear()
        rig.sut.didDisappear()
        rig.subject.send(NeedsYouSnapshot(phase: .ready, items: []))
        // then
        verify(rig.useCase).snapshotPublisher().called(1)
        rig.sut.didAppear()
        verify(rig.useCase).snapshotPublisher().called(2)
        await waitUntil { rig.sut.presentation.rows.isEmpty }
    }

    @Test func givenLoadingSnapshot_whenAppeared_thenPresentationIsLoading() async {
        // given
        let rig = rig(items: [], phase: .loading)
        // when
        rig.sut.didAppear()
        await waitUntil { rig.sut.presentation.summary.hasPrefix("Checking") }
        // then
        #expect(rig.sut.presentation.isLoading)
    }

    @Test func givenUnchangedSnapshots_whenRepublished_thenPresentationIsNotRewritten() async {
        // given
        let rig = rig(items: [item()])
        rig.sut.didAppear()
        await waitUntil { rig.sut.presentation.rows.count == 1 }
        let before = rig.sut.presentation
        // when
        rig.subject.send(rig.subject.value)
        rig.sut.rebuild()
        await waitUntil { true }
        // then
        #expect(rig.sut.presentation == before)
    }

    @Test func givenItemID_whenShown_thenDetailIsBuiltWithProvenance() async {
        // given
        let rig = rig(items: [item()])
        rig.sut.didAppear()
        // when
        rig.sut.show(itemID: "input:w1:d1")
        await waitUntil { rig.sut.presentation.detail != nil }
        // then
        let detail = rig.sut.presentation.detail
        #expect(detail?.provenance.map(\.label).contains("Engine note") == true)
        #expect(detail?.provenance.first { $0.label == "Caller" }?.value == "Ended")
        #expect(detail?.phase == .answerable && rig.sut.presentation.showsDetail)
    }

    @Test func givenAcceptedAnswer_whenSent_thenSettledCardShowsAnswerAndOwnershipCopy() async {
        // given
        let rig = rig(items: [item()])
        rig.sut.didAppear()
        rig.sut.show(itemID: "input:w1:d1")
        await waitUntil { rig.sut.presentation.detail != nil }
        rig.sut.answerText = "Use staging."
        // when
        rig.sut.didSubmitAnswer()
        await waitUntil { if case .settled? = rig.sut.presentation.detail?.phase { true } else { false } }
        // then
        guard case .settled(let decision, let answer, let note)? = rig.sut.presentation.detail?.phase else {
            Issue.record("expected a settled card")
            return
        }
        #expect(decision == "Answered" && answer == "Use staging.")
        #expect(note.hasPrefix("Harflow now owns this run. The original caller can no longer answer it"))
        verify(rig.useCase).answer(.any, text: .value("Use staging."), additionalAttempts: .value(nil)).called(1)
    }

    @Test func givenAcceptedAnswerWithMotion_whenSent_thenRowLeavesAfterTheFade() async {
        // given
        let rig = rig(items: [item()], reduceMotion: false)
        rig.sut.didAppear()
        rig.sut.show(itemID: "input:w1:d1")
        await waitUntil { rig.sut.presentation.detail != nil }
        rig.sut.answerText = "x"
        // when
        rig.subject.send(NeedsYouSnapshot(phase: .ready, items: []))
        rig.sut.didSubmitAnswer()
        await waitUntil { rig.sut.presentation.rows.first?.isLeaving == true }
        // then
        await waitUntil { rig.sut.presentation.rows.isEmpty }
        #expect(rig.sut.presentation.rows.isEmpty)
    }

    @Test func givenCallerReturned_whenSent_thenListShowsNoticeAndUnsentTextIsDiscarded() async {
        // given
        let rig = rig(items: [item()], outcome: .callerReturned("The caller is answering this again."))
        rig.sut.didAppear()
        rig.sut.show(itemID: "input:w1:d1")
        await waitUntil { rig.sut.presentation.detail != nil }
        rig.sut.answerText = "draft"
        // when
        rig.sut.didSubmitAnswer()
        await waitUntil { rig.sut.presentation.notice != nil }
        // then
        #expect(rig.sut.presentation.notice == "The caller is answering this again.")
        #expect(rig.sut.answerText.isEmpty && !rig.sut.presentation.showsDetail)
        #expect(rig.routed.all == [nil])
    }

    @Test(arguments: [NeedsYouAnswerOutcome.stale("moved on"), NeedsYouAnswerOutcome.failed("boom")])
    func givenStaleOrFailed_whenSent_thenTextIsKeptAndMessageShown(outcome: NeedsYouAnswerOutcome) async {
        // given
        let rig = rig(items: [item()], outcome: outcome)
        rig.sut.didAppear()
        rig.sut.show(itemID: "input:w1:d1")
        await waitUntil { rig.sut.presentation.detail != nil }
        rig.sut.answerText = "keep me"
        // when
        rig.sut.didSubmitAnswer()
        await waitUntil { rig.sut.presentation.detail?.error != nil }
        // then
        #expect(rig.sut.answerText == "keep me")
        #expect(rig.sut.presentation.detail?.phase == .answerable)
    }

    @Test func givenChangedApproval_whenDecided_thenRefreshedActionIsShownWithReviewNote() async {
        // given
        var approval = item("approval:t1:r1", kind: .approval)
        approval.approval = CallerApprovalRequest(raw: ["request_id": .string("r1"), "task_id": .string("t1"), "owner_revision": .number(1),
                                                        "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("ls")])])])
        var refreshed = approval
        refreshed.approval = CallerApprovalRequest(raw: ["request_id": .string("r1"), "task_id": .string("t1"), "owner_revision": .number(2),
                                                         "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("rm")])])])
        let rig = rig(items: [approval], outcome: .changed(refreshed))
        rig.sut.didAppear()
        rig.sut.show(itemID: approval.id)
        await waitUntil { rig.sut.presentation.detail != nil }
        // when
        rig.sut.didDecide(approve: true)
        await waitUntil { rig.sut.presentation.detail?.reviewNote != nil }
        // then
        #expect(rig.sut.presentation.detail?.reviewNote == "This request changed. Review it again.")
        #expect(rig.sut.presentation.detail?.approval?.fields.contains { $0.value == "rm" } == true)
    }

    @Test func givenApprovalAccepted_whenRejected_thenSettledSaysRejected() async {
        // given
        var approval = item("approval:t1:r1", kind: .approval)
        approval.rootRunID = ""
        let rig = rig(items: [approval])
        rig.sut.didAppear()
        rig.sut.show(itemID: approval.id)
        await waitUntil { rig.sut.presentation.detail != nil }
        // when
        rig.sut.didDecide(approve: false)
        await waitUntil { if case .settled? = rig.sut.presentation.detail?.phase { true } else { false } }
        // then
        guard case .settled(let decision, _, _)? = rig.sut.presentation.detail?.phase else {
            Issue.record("not settled")
            return
        }
        #expect(decision == "Rejected")
    }

    @Test func givenOpenRequestResolvedElsewhere_whenSnapshotDropsIt_thenExpiredCardShowsAndNothingIsSent() async {
        // given
        let rig = rig(items: [item()])
        rig.sut.didAppear()
        rig.sut.show(itemID: "input:w1:d1")
        await waitUntil { rig.sut.presentation.detail?.phase == .answerable }
        // when
        rig.subject.send(NeedsYouSnapshot(phase: .ready, items: []))
        await waitUntil { rig.sut.presentation.detail?.phase == .expired }
        // then
        #expect(rig.sut.presentation.detail?.title == "Release")
        verify(rig.useCase).answer(.any, text: .any, additionalAttempts: .any).called(0)
    }

    @Test func givenRetry_whenTapped_thenAnImmediatePassIsRequested() {
        // given
        let rig = rig(items: [])
        // when
        rig.sut.didTapRetry()
        // then
        verify(rig.useCase).refresh().called(1)
    }

    @Test func givenRowTapped_whenSelected_thenRoutingCarriesTheItemID() {
        // given
        let rig = rig(items: [item()])
        // when
        rig.sut.didSelect("input:w1:d1")
        rig.sut.didTapBack()
        // then
        #expect(rig.routed.all == ["input:w1:d1", nil])
    }

    @Test func givenUsageLimitItem_whenOfferedAnswerChosen_thenExactAnswerIsSent() async {
        // given
        var usage = item()
        usage.offeredAnswers = ["retry", "switch"]
        let rig = rig(items: [usage])
        rig.sut.didAppear()
        rig.sut.show(itemID: usage.id)
        await waitUntil { rig.sut.presentation.detail != nil }
        // when
        rig.sut.didChooseOffered("something else")
        rig.sut.didChooseOffered("switch")
        await waitUntil { if case .settled? = rig.sut.presentation.detail?.phase { true } else { false } }
        // then
        verify(rig.useCase).answer(.any, text: .value("switch"), additionalAttempts: .any).called(1)
        verify(rig.useCase).answer(.any, text: .value("something else"), additionalAttempts: .any).called(0)
    }

    @Test func givenRecoveryWithAttempts_whenSent_thenAdditionalAttemptsTravelWithTheAnswer() async {
        // given
        var recovery = item("attention:w1:w1:abcd1234", kind: .recovery)
        recovery.canAddAttempts = true
        let rig = rig(items: [recovery])
        rig.sut.didAppear()
        rig.sut.show(itemID: recovery.id)
        await waitUntil { rig.sut.presentation.detail != nil }
        rig.sut.answerText = "Keep 1.2"
        rig.sut.additionalAttempts = 3
        // when
        rig.sut.didSubmitAnswer()
        await waitUntil { if case .settled? = rig.sut.presentation.detail?.phase { true } else { false } }
        // then
        verify(rig.useCase).answer(.any, text: .value("Keep 1.2"), additionalAttempts: .value(3)).called(1)
    }

    private func approvalItem(revision: Int, command: String) -> NeedsYouItem {
        var value = item("approval:t1:r1", kind: .approval)
        value.rootRunID = ""
        value.approval = CallerApprovalRequest(raw: [
            "request_id": .string("r1"), "task_id": .string("t1"), "owner_revision": .number(Double(revision)),
            "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string(command)])])
        ])
        return value
    }

    @Test func givenSnapshotUpdatedAfterRender_whenDecisionTapped_thenNothingIsSentAndTheChangedNoteShows() async {
        // given
        let shown = approvalItem(revision: 1, command: "ls")
        let rig = rig(items: [shown])
        rig.sut.didAppear()
        rig.sut.show(itemID: shown.id)
        await waitUntil { rig.sut.displayedItem == shown }
        // when — the live item moves on before the presentation catches up.
        rig.sut.snapshot = NeedsYouSnapshot(phase: .ready, items: [approvalItem(revision: 2, command: "rm -rf build")])
        rig.sut.didDecide(approve: true)
        await waitUntil { rig.sut.presentation.detail?.reviewNote != nil }
        // then
        #expect(rig.sut.presentation.detail?.reviewNote == "This request changed. Review it again.")
        #expect(rig.sut.presentation.detail?.approval?.fields.contains { $0.value == "rm -rf build" } == true)
        verify(rig.useCase).respond(.any, decision: .any).called(0)
        await waitUntil { rig.sut.displayedItem?.approval?.revision == 2 }
    }

    @Test func givenQuestionReplacedAfterRender_whenAnswerSent_thenNothingIsSent() async {
        // given
        let shown = item()
        let rig = rig(items: [shown])
        rig.sut.didAppear()
        rig.sut.show(itemID: shown.id)
        await waitUntil { rig.sut.displayedItem == shown }
        rig.sut.answerText = "Use staging."
        var replaced = shown
        replaced.decisionID = "d2"
        replaced.text = "A different question?"
        // when
        rig.sut.snapshot = NeedsYouSnapshot(phase: .ready, items: [replaced])
        rig.sut.didSubmitAnswer()
        await waitUntil { rig.sut.presentation.detail?.reviewNote != nil }
        // then
        verify(rig.useCase).answer(.any, text: .any, additionalAttempts: .any).called(0)
        #expect(rig.sut.answerText == "Use staging." && rig.sut.presentation.detail?.text == "A different question?")
    }

    @Test func givenUnchangedItem_whenDecisionTapped_thenTheDisplayedItemIsExactlyWhatIsSent() async {
        // given
        let shown = approvalItem(revision: 1, command: "ls")
        let rig = rig(items: [shown])
        rig.sut.didAppear()
        rig.sut.show(itemID: shown.id)
        await waitUntil { rig.sut.displayedItem == shown }
        // when
        rig.sut.didDecide(approve: true)
        await waitUntil { if case .settled? = rig.sut.presentation.detail?.phase { true } else { false } }
        // then
        verify(rig.useCase).respond(.value(shown), decision: .value("approve")).called(1)
    }
}
