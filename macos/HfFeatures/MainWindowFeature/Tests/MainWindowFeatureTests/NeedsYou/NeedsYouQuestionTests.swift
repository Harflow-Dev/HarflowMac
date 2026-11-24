import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - NeedsYouQuestionTests

@MainActor @Suite struct NeedsYouQuestionTests {
    private func item(_ id: String) -> NeedsYouItem {
        NeedsYouItem(id: id, kind: .question, rootRunID: "run", sourceRunID: "source", runTitle: "Release",
                     pathTitles: ["Release", "Choose"], text: "Question \(id)",
                     ownership: .init(owner: "monitor", callerEnded: false, engineNote: "", handover: nil, sharedAnswering: true),
                     startedBy: "Caller", decisionID: id)
    }

    private func fixture(_ items: [NeedsYouItem], context: WorkflowResponseContext? = nil) -> QuestionCardHostedFixture {
        let fixture = QuestionCardHostedFixture()
        fixture.useCase.subject.send(NeedsYouSnapshot(phase: .ready, items: items, workflowContext: context))
        fixture.vm.didAppear()
        return fixture
    }

    @Test func givenTwoQuestions_whenDraftsAndErrorsChange_thenOnlyTheExactCardChanges() async throws {
        // given
        let firstItem = item("firstItem"), secondItem = item("secondItem")
        let rig = fixture([firstItem, secondItem])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 2 }
        let first = try #require(rig.vm.presentation.questions.first)
        let second = try #require(rig.vm.presentation.questions.last)
        // when
        rig.vm.setQuestionDraft("A draft", for: first)
        rig.vm.setQuestionDraft("B draft", for: second)
        rig.useCase.answerOutcome = .failed("A refused")
        rig.vm.submitQuestion(first, offered: nil)
        await waitUntil { rig.vm.presentation.questions.first?.detail.error == "A refused" }
        // then
        #expect(rig.vm.questionDraft(for: first) == "A draft")
        #expect(rig.vm.questionDraft(for: second) == "B draft")
        #expect(rig.vm.presentation.questions.last?.detail.error == nil)
        #expect(rig.useCase.answers.first?.0 == firstItem)
    }

    @Test func givenUnknownOutcome_whenFinished_thenShownAsTodaysFailure() async throws {
        // given
        let rig = fixture([item("only")])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let card = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("A draft", for: card)
        rig.useCase.answerOutcome = .unknown("harflow-ctl did not answer within 30 s.")
        // when
        rig.vm.submitQuestion(card, offered: nil)
        await waitUntil { rig.vm.presentation.questions.first?.detail.error == "harflow-ctl did not answer within 30 s." }
        // then
        #expect(rig.vm.questionDraft(for: card) == "A draft")
    }

    @Test func givenFailureWithCode_whenFinished_thenTheLegacyTextIsShown() async throws {
        // given
        let rig = fixture([item("only")])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let card = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("A draft", for: card)
        rig.useCase.answerOutcome = .failed(message: "Busy", code: "session_busy", legacyText: "Busy (session_busy)")
        // when
        rig.vm.submitQuestion(card, offered: nil)
        await waitUntil { rig.vm.presentation.questions.first?.detail.error == "Busy (session_busy)" }
        // then
        #expect(rig.vm.presentation.questions.first?.detail.error == "Busy (session_busy)")
    }

    @Test func givenOldRenderedTarget_whenCheckpointReplaced_thenDraftAndActionCannotRetarget() async throws {
        // given
        let firstItem = item("same")
        let rig = fixture([firstItem])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let old = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("old draft", for: old)
        var replacement = firstItem
        replacement.attentionCheckpointID = "new checkpoint"
        // when — callbacks race the asynchronously delivered snapshot.
        rig.useCase.subject.send(NeedsYouSnapshot(phase: .ready, items: [replacement]))
        rig.vm.submitQuestion(old, offered: nil)
        rig.vm.setQuestionDraft("must not transfer", for: old)
        await waitUntil { rig.vm.presentation.questions.contains { $0.item == replacement } }
        // then
        let new = try #require(rig.vm.presentation.questions.first { $0.item == replacement })
        #expect(new.id != old.id && new.draft.isEmpty)
        #expect(rig.useCase.answerCalls == 0)
    }

    @Test func givenWithdrawal_whenRetryTapped_thenDraftRemainsAndNoAnswerCanBeSent() async throws {
        // given
        let firstItem = item("firstItem")
        let rig = fixture([firstItem])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let card = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("Keep draft", for: card)
        // when
        rig.useCase.subject.send(NeedsYouSnapshot(phase: .ready, items: [], withdrawn: [firstItem]))
        await waitUntil { rig.vm.presentation.questions.first?.detail.phase == .withdrawn }
        let withdrawn = try #require(rig.vm.presentation.questions.first)
        let refreshes = rig.useCase.refreshCalls
        rig.vm.retryQuestion(withdrawn)
        rig.vm.submitQuestion(withdrawn, offered: nil)
        // then
        #expect(rig.useCase.refreshCalls == refreshes + 1)
        #expect(rig.vm.questionDraft(for: withdrawn) == "Keep draft")
        #expect(rig.useCase.answerCalls == 0)
    }

    @Test func givenCallerWins_whenAnswerCompletes_thenReceiptKeepsDraftAndPendingCountExcludesOnlyThatRequest() async throws {
        // given
        let rig = fixture([item("firstItem"), item("secondItem")])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 2 }
        let card = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("My unsent draft", for: card)
        rig.useCase.answerOutcome = .alreadyAnswered(answer: "Winner", answeredBy: .caller, answeredAt: 1793059200)
        // when
        rig.vm.submitQuestion(card, offered: nil)
        await waitUntil { rig.vm.presentation.questions.first?.terminal == true }
        // then
        #expect(rig.vm.presentation.questions.first?.detail.savedDraft == "My unsent draft")
        #expect(rig.vm.presentation.summary == "1 request you can answer")
        #expect(rig.routing.selections.isEmpty)
        #expect(rig.vm.presentation.questions.count == 2)
    }

    @Test func givenCallerReturned_whenAnswerCompletes_thenOnlyThatCardBecomesReadOnlyWithoutNavigation() async throws {
        // given
        let rig = fixture([item("firstItem"), item("secondItem")])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 2 }
        let card = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("Draft", for: card)
        rig.useCase.answerOutcome = .callerReturned("The caller is answering this again.")
        // when
        rig.vm.submitQuestion(card, offered: nil)
        await waitUntil { rig.vm.presentation.questions.first?.terminal == true }
        // then
        #expect(rig.vm.presentation.questions.first?.detail.phase == .readOnly(lines: ["The caller is answering this again."], refresh: false))
        #expect(rig.vm.presentation.questions.last?.detail.phase == .answerable)
        #expect(rig.routing.selections.isEmpty)
    }

    @Test func givenOfferedAnswers_whenBlankOrInventedAnswerSent_thenOnlyExactOfferedTokenIsDispatched() async throws {
        // given
        var firstItem = item("offered")
        firstItem.offeredAnswers = ["retry", "switch"]
        let rig = fixture([firstItem])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let card = try #require(rig.vm.presentation.questions.first)
        // when
        rig.vm.setQuestionDraft("invented", for: card)
        rig.vm.submitQuestion(card, offered: nil)
        rig.vm.submitQuestion(card, offered: "invented")
        #expect(rig.useCase.answerCalls == 0)
        rig.vm.submitQuestion(card, offered: "switch")
        await waitUntil { rig.useCase.answerCalls == 1 }
        // then
        #expect(rig.useCase.answers.first?.1 == "switch")
    }

    @Test func givenUnresolvedDraftsBeyondReceiptBound_whenRebuilt_thenNoDraftIsEvicted() async {
        // given
        let rig = fixture((0 ... NeedsYouVM.settledLimit).map { item("q\($0)") })
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == NeedsYouVM.settledLimit + 1 }
        // when
        for card in rig.vm.presentation.questions { rig.vm.setQuestionDraft("draft \(card.item.id)", for: card) }
        rig.vm.rebuild()
        await waitUntil { rig.vm.presentation.questions.allSatisfy { !$0.draft.isEmpty } }
        // then
        #expect(rig.vm.presentation.questions.count == NeedsYouVM.settledLimit + 1)
    }

    @Test func givenAnswerInFlight_whenEmptyRuntimeBThenAReturns_thenOldCompletionCannotTouchNewMount() async throws {
        // given
        let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
        let contextA = WorkflowResponseContext(runtime: runtime, epoch: UUID())
        let contextB = WorkflowResponseContext(runtime: runtime, epoch: UUID())
        var firstItem = item("same")
        firstItem.workflowContext = contextA
        let rig = fixture([firstItem], context: contextA)
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let old = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("A draft", for: old)
        rig.useCase.holdAnswers = true
        rig.vm.submitQuestion(old, offered: nil)
        await waitUntil { rig.useCase.answerCalls == 1 }
        // when
        rig.useCase.subject.send(NeedsYouSnapshot(phase: .loading, items: [], workflowContext: contextB))
        await waitUntil { rig.vm.questions.isEmpty }
        rig.useCase.subject.send(NeedsYouSnapshot(phase: .ready, items: [firstItem], workflowContext: contextA))
        await waitUntil { rig.vm.presentation.questions.count == 1 && rig.vm.presentation.questions.first?.id != old.id }
        let fresh = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("Fresh A", for: fresh)
        rig.useCase.completeAnswer(.accepted)
        await waitUntil { rig.useCase.returnedAnswerCalls == 1 }
        try #require(rig.useCase.returnedAnswerCalls == 1)
        // then
        #expect(rig.vm.questionDraft(for: fresh) == "Fresh A")
        #expect(rig.vm.questions.first?.terminal == false)
        rig.vm.submitQuestion(old, offered: nil)
        #expect(rig.useCase.answerCalls == 1)
    }

    @Test func givenInFlightAnswer_whenScreenDisappearsAndReappears_thenNoInlineStateOrLateReceiptReturns() async throws {
        // given
        let rig = fixture([item("firstItem")])
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let card = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("Old draft", for: card)
        rig.useCase.holdAnswers = true
        rig.vm.submitQuestion(card, offered: nil)
        await waitUntil { rig.useCase.answerCalls == 1 }
        // when
        rig.vm.didDisappear()
        rig.vm.didAppear()
        defer { rig.vm.didDisappear() }
        await waitUntil {
            guard let fresh = rig.vm.presentation.questions.first else { return false }
            return fresh.id != card.id
        }
        let fresh = try #require(rig.vm.presentation.questions.first)
        try #require(fresh.id != card.id)
        rig.useCase.completeAnswer(.accepted)
        // The fake marks return in the same main-actor task that immediately applies/rejects the VM completion.
        await waitUntil { rig.useCase.returnedAnswerCalls == 1 }
        try #require(rig.useCase.returnedAnswerCalls == 1)
        // then
        #expect(rig.vm.questions.first?.draft.isEmpty == true)
        #expect(rig.vm.questions.first?.terminal == false)
    }

    @Test(arguments: [false, true])
    func givenInlineAnswer_whenDeepLinkOpened_thenExactReceiptIsSharedButReplacementCannotBeOverlaid(winner: Bool) async throws {
        // given
        let original = item("receipt")
        let rig = fixture([original])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let card = try #require(rig.vm.presentation.questions.first)
        rig.vm.setQuestionDraft("My draft", for: card)
        rig.useCase.answerOutcome = winner
            ? .alreadyAnswered(answer: "Winning answer", answeredBy: .caller, answeredAt: 1793059200)
            : .accepted
        // when
        rig.vm.submitQuestion(card, offered: nil)
        await waitUntil { rig.vm.settled[original.id] != nil }
        rig.vm.didSelect(original.id)
        await waitUntil { rig.vm.presentation.detail?.phase == rig.vm.settled[original.id]?.phase }
        // then
        #expect(rig.vm.presentation.detail?.savedDraft == (winner ? "My draft" : nil))
        guard case .settled(_, let answer, _)? = rig.vm.presentation.detail?.phase else {
            Issue.record("Expected the inline receipt in the selected detail"); return
        }
        #expect(answer == (winner ? "Winning answer" : "My draft"))
        var replacement = original
        replacement.attentionCheckpointID = "replacement checkpoint"
        rig.useCase.subject.send(.init(phase: .ready, items: [replacement]))
        await waitUntil { rig.vm.displayedItem == replacement }
        #expect(rig.vm.settled[original.id] == nil)
        #expect(rig.vm.presentation.detail?.phase == .answerable)
    }

    @Test func givenMoreThan32WinnersWithDrafts_whenSourcesKeepReportingThem_thenReceiptsStayBoundedAndEvictionNeverReoffersAnAnswer() async throws {
        // given
        let items = (0 ..< 35).map { item("winner-\($0)") }
        let pending = item("pending"), unreadable = item("unreadable")
        let rig = fixture(items + [pending, unreadable])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 37 }
        let pendingCard = try #require(rig.vm.questions.first { $0.item.id == pending.id })
        let unreadableCard = try #require(rig.vm.questions.first { $0.item.id == unreadable.id })
        rig.vm.setQuestionDraft("Pending draft", for: pendingCard)
        rig.vm.setQuestionDraft("Unreadable draft", for: unreadableCard)
        rig.useCase.subject.send(.init(phase: .ready, items: items + [pending], withdrawn: [unreadable]))
        await waitUntil { rig.vm.questions.first { $0.item.id == unreadable.id }?.detail.phase == .withdrawn }
        let oldest = try #require(rig.vm.questions.first { $0.item.id == items[0].id })
        // when
        for item in items {
            let card = try #require(rig.vm.questions.first { $0.item.id == item.id })
            rig.vm.setQuestionDraft("Local draft \(item.id)", for: card)
            rig.useCase.answerOutcome = .alreadyAnswered(answer: "Winner", answeredBy: .caller, answeredAt: 1793059200)
            rig.vm.submitQuestion(card, offered: nil)
            await waitUntil { rig.vm.presentation.questions.first { $0.id == card.id }?.terminal == true }
        }
        // then
        #expect(rig.vm.questions.filter { !$0.isPending }.count == NeedsYouVM.settledLimit)
        #expect(rig.vm.questions.filter { !$0.isPending }.allSatisfy { $0.detail.savedDraft != nil })
        #expect(rig.vm.questionDraft(for: pendingCard) == "Pending draft")
        #expect(rig.vm.questionDraft(for: unreadableCard) == "Unreadable draft")
        #expect(rig.vm.questionSuppressed.count == 3)
        let sent = rig.useCase.answerCalls
        rig.vm.submitQuestion(oldest, offered: nil)
        rig.vm.rebuild()
        await waitUntil { rig.vm.presentation.summary == "1 request you can answer" }
        #expect(rig.useCase.answerCalls == sent)
        #expect(!rig.vm.questions.contains { $0.id == oldest.id })
        // Authoritative absence retires the lightweight identity; a new request with the same ID can answer.
        rig.useCase.subject.send(.init(phase: .ready, items: [pending], withdrawn: [unreadable]))
        await waitUntil { rig.vm.questionSuppressed.isEmpty }
        var replacement = items[0]
        replacement.attentionCheckpointID = "new checkpoint"
        rig.useCase.subject.send(.init(phase: .ready, items: [replacement, pending], withdrawn: [unreadable]))
        await waitUntil { rig.vm.questions.contains { $0.item == replacement && $0.isPending } }
        let fresh = try #require(rig.vm.questions.first { $0.item == replacement })
        rig.vm.setQuestionDraft("New answer", for: fresh)
        rig.vm.submitQuestion(fresh, offered: nil)
        await waitUntil { rig.useCase.answerCalls == sent + 1 }
        #expect(fresh.id != oldest.id)
    }

    @Test(arguments: [false, true])
    func givenDetailAnswer_whenReturningToListWithLaggingOrRemovedSource_thenInlineReceiptRemainsTruthfulAndCannotResend(sourceRemoved: Bool) async throws {
        // given
        let original = item("detail-answer")
        let rig = fixture([original])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let inline = try #require(rig.vm.questions.first)
        rig.vm.setQuestionDraft("Unsent inline draft", for: inline)
        rig.vm.didSelect(original.id)
        await waitUntil { rig.vm.displayedItem == original }
        rig.vm.answerText = "Actual selected-detail answer"
        // when
        rig.vm.didSubmitAnswer()
        await waitUntil { rig.vm.settled[original.id] != nil }
        if sourceRemoved { rig.useCase.subject.send(.init(phase: .ready, items: [])) }
        rig.vm.didTapBack()
        await waitUntil {
            !rig.vm.presentation.showsDetail && rig.vm.presentation.questions.first?.terminal == true
                && rig.vm.presentation.summary == "Nothing needs you"
        }
        // then
        let receipt = try #require(rig.vm.presentation.questions.first)
        guard case .settled(_, let answer, _) = receipt.detail.phase else {
            Issue.record("Expected truthful inline receipt after selected-detail answer"); return
        }
        #expect(answer == "Actual selected-detail answer")
        #expect(receipt.detail.savedDraft == "Unsent inline draft")
        #expect(!receipt.isPending)
        rig.vm.submitQuestion(inline, offered: nil)
        rig.vm.submitQuestion(receipt, offered: nil)
        #expect(rig.useCase.answerCalls == 1)
    }

    enum SuspendedOutcome: CaseIterable { case accepted, failed, stale }

    @Test(arguments: [false, true], SuspendedOutcome.allCases)
    func givenInFlightAnswer_whenSourceDisappearsOrChanges_thenOnlyOldMountKeepsAttemptAndResult(replaced: Bool, outcome: SuspendedOutcome) async throws {
        // given
        let original = item("in-flight")
        let rig = fixture([original])
        defer { rig.vm.didDisappear() }
        await waitUntil { rig.vm.presentation.questions.count == 1 }
        let old = try #require(rig.vm.questions.first)
        rig.vm.setQuestionDraft("Original answer", for: old)
        rig.useCase.holdAnswers = true
        rig.vm.submitQuestion(old, offered: nil)
        await waitUntil { rig.useCase.answerCalls == 1 }
        var replacement = original
        replacement.attentionCheckpointID = "new checkpoint"
        // when
        rig.useCase.subject.send(.init(phase: .ready, items: replaced ? [replacement] : []))
        await waitUntil {
            rig.vm.presentation.questions.first { $0.id == old.id }?.absentSeen == true
                && (!replaced || rig.vm.presentation.questions.contains { $0.item == replacement })
        }
        let pendingOld = try #require(rig.vm.presentation.questions.first { $0.id == old.id })
        #expect(pendingOld.submitting && pendingOld.detail.phase == .submitting)
        #expect(!pendingOld.terminal)
        if replaced {
            let fresh = try #require(rig.vm.questions.first { $0.item == replacement })
            rig.vm.setQuestionDraft("Replacement draft", for: fresh)
        }
        let completion: NeedsYouAnswerOutcome = switch outcome {
        case .accepted: .accepted
        case .failed: .failed("The answer could not be confirmed.")
        case .stale: .stale("This request changed during the answer attempt.")
        }
        rig.useCase.completeAnswer(completion)
        await waitUntil { rig.useCase.returnedAnswerCalls == 1 && rig.vm.presentation.questions.first { $0.id == old.id }?.terminal == true }
        // then
        let completedOld = try #require(rig.vm.presentation.questions.first { $0.id == old.id })
        #expect(!completedOld.submitting && !completedOld.isPending)
        if outcome == .accepted {
            guard case .settled(_, let answer, _) = completedOld.detail.phase else {
                Issue.record("The original accepted attempt must retain its receipt"); return
            }
            #expect(answer == "Original answer")
        } else {
            guard case .readOnly(let lines, let refresh) = completedOld.detail.phase else {
                Issue.record("A failed attempted answer must not claim nothing was sent"); return
            }
            #expect(!lines.isEmpty && !refresh)
            #expect(completedOld.detail.savedDraft == "Original answer")
        }
        if replaced {
            let fresh = try #require(rig.vm.questions.first { $0.item == replacement })
            #expect(fresh.id != old.id && fresh.draft == "Replacement draft")
            #expect(fresh.detail.phase == .answerable && !fresh.terminal)
            #expect(rig.vm.settled[replacement.id] == nil)
        }
        rig.vm.submitQuestion(completedOld, offered: nil)
        #expect(rig.useCase.answerCalls == 1)
    }

    @Test func givenReceiptPressure_whenAbsentQuestionIsStillSubmitting_thenItsAttemptIsNotEvictedOrCalledUnsent() {
        // given
        let original = item("still-submitting")
        var inFlight = NeedsYouQuestion(id: UUID(), item: original, detail: NeedsYouPresentationMapper.detail(original), draft: "Attempted answer")
        inFlight.submitting = true
        var receipts = (0 ... NeedsYouVM.settledLimit).map { index in
            let item = item("receipt-\(index)")
            var detail = NeedsYouPresentationMapper.detail(item)
            detail.phase = .settled(decision: "Answered", answer: "Winner", note: "")
            return NeedsYouQuestion(id: UUID(), item: item, detail: detail, isPending: false, terminal: true)
        }
        receipts.insert(inFlight, at: 0)
        // when
        let result = NeedsYouQuestionAssembly.reconcile(receipts, suppressed: [], snapshot: .init(phase: .ready, items: []))
        // then
        #expect(result.cards.count == NeedsYouVM.settledLimit + 1)
        #expect(result.cards.first?.id == inFlight.id)
        #expect(result.cards.first?.detail.phase == .submitting)
        #expect(result.cards.first?.draft == "Attempted answer")
    }

}
