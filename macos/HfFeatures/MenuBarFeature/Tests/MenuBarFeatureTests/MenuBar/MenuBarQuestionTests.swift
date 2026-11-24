import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Testing

// MARK: - MenuBarQuestionTests

@MainActor
@Suite struct MenuBarQuestionTests {
    private final class Feed: MenuBarNeedsYouUseCase {
        let subject: CurrentValueSubject<NeedsYouSnapshot, Never>
        var answers: [(item: NeedsYouItem, text: String)] = []
        var outcome: NeedsYouAnswerOutcome = .accepted
        /// While set, `answerQuestion` waits until `release()`.
        var gated = false
        private var waiter: CheckedContinuation<Void, Never>?
        init(_ snapshot: NeedsYouSnapshot) { self.subject = CurrentValueSubject(snapshot) }
        var needsYouSnapshot: NeedsYouSnapshot { subject.value }
        func needsYouSnapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { subject.eraseToAnyPublisher() }
        func answerQuestion(_ item: NeedsYouItem, text: String) async -> NeedsYouAnswerOutcome {
            answers.append((item, text))
            if gated { await withCheckedContinuation { waiter = $0 } }
            return outcome
        }

        func release() { waiter?.resume(); waiter = nil }
    }

    private func item(_ id: String = "input:a:1", kind: NeedsYouItem.Kind = .question, offered: [String]? = nil) -> NeedsYouItem {
        var value = NeedsYouItem(id: id, kind: kind, runTitle: "Run \(id)", text: "Upgrade?",
                                 ownership: .init(owner: "caller", callerEnded: false, engineNote: "", handover: nil), startedBy: "Original caller")
        value.offeredAnswers = offered
        return value
    }

    private func makeSUT(_ items: [NeedsYouItem]) -> (sut: MenuBarVM, feed: Feed, routing: MockMenuBarRouting) {
        let useCase = MockMenuBarUseCase()
        let routing = MockMenuBarRouting()
        given(useCase).connectionLine.willReturn("connected")
        given(useCase).runningCount.willReturn(0)
        given(useCase).runtimeSetupState.willReturn(.ready)
        given(useCase).runtimeSetupStatePublisher().willReturn(Just(RuntimeSetupState.ready).eraseToAnyPublisher())
        given(useCase).workAvailable.willReturn(true)
        given(useCase).workAvailablePublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(useCase).refreshWork().willReturn()
        given(useCase).tasksPublisher().willReturn(Just([]).eraseToAnyPublisher())
        given(useCase).countsPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(Just(nil).eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(routing).select(.any).willReturn()
        given(routing).openWindow().willReturn()
        let feed = Feed(NeedsYouSnapshot(phase: .ready, items: items))
        let sut = MenuBarVM(useCase: useCase, routing: routing, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler(), needsYou: feed)
        sut.didAppear()
        return (sut, feed, routing)
    }

    private func submit(_ sut: MenuBarVM, feed: Feed, draft: String, id: String = "input:a:1", outcome: NeedsYouAnswerOutcome) async {
        feed.outcome = outcome
        sut.didEditAnswer(id, text: draft)
        sut.didSubmitAnswer(id)
        await waitUntil { feed.answers.count == 1 && sut.questionPhases[id] != .submitting }
    }

    private func state(_ sut: MenuBarVM, _ id: String = "input:a:1") -> MenuBarQuestionState? {
        sut.needsYou?.rows.first { $0.id == id }?.question
    }

    // MARK: Section

    @Test func givenAPlainQuestion_whenSectionBuilt_thenRowHasAnEditableCard() {
        // given / when
        let (sut, _, _) = makeSUT([item()])
        // then
        #expect(state(sut) == MenuBarQuestionState(draft: "", phase: .editing))
    }

    @Test func givenOfferedAnswers_whenSectionBuilt_thenRowOpensTheWindowInstead() {
        // given / when
        let (sut, _, _) = makeSUT([item(offered: ["retry"])])
        // then
        #expect(sut.needsYou?.rows.first?.question == nil)
    }

    @Test func givenARecovery_whenSectionBuilt_thenNoCard() {
        // given / when
        let (sut, _, _) = makeSUT([item(kind: .recovery)])
        // then
        #expect(sut.needsYou?.rows.first?.question == nil)
    }

    // MARK: Submit

    @Test func givenEmptyDraft_whenSubmitted_thenNothingIsSent() {
        // given
        let (sut, feed, _) = makeSUT([item()])
        // when
        sut.didSubmitAnswer("input:a:1")
        sut.didEditAnswer("input:a:1", text: "  \n")
        sut.didSubmitAnswer("input:a:1")
        // then
        #expect(feed.answers.isEmpty)
        #expect(state(sut)?.phase == .editing)
    }

    @Test func givenADraft_whenSubmitted_thenOneAnswerWithTheDraftAndSubmittingPhase() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        feed.gated = true
        // when
        sut.didEditAnswer("input:a:1", text: "Yes")
        sut.didSubmitAnswer("input:a:1")
        sut.didSubmitAnswer("input:a:1")
        await waitUntil { feed.answers.count == 1 }
        // then
        #expect(feed.answers.count == 1 && feed.answers.first?.text == "Yes")
        #expect(state(sut)?.phase == .submitting && state(sut)?.draft == "Yes")
        feed.release()
        await waitUntil { state(sut)?.phase != .submitting }
    }

    @Test func givenAccepted_whenFinished_thenSettledAnsweredWithTheSettledNoteAndRowHeldUntilClose() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        // when
        await submit(sut, feed: feed, draft: " Yes ", outcome: .accepted)
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: []))
        await waitUntil { (sut.needsYou?.count ?? -1) == 0 }
        // then
        #expect(state(sut)?.phase == .settled(title: "Answered", lines: ["Yes", "Run input:a:1 no longer needs you."], action: .none))
        #expect(state(sut)?.draft == "")
        #expect(sut.needsYou?.rows.count == 1)
        // when
        sut.didPopoverClose()
        // then
        #expect(sut.needsYou?.rows.isEmpty == true)
    }

    @Test func givenAlreadyAnsweredByTheCaller_whenFinished_thenSettledWithAnswerTimeAndSavedDraft() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        // when
        await submit(sut, feed: feed, draft: "Mine", outcome: .alreadyAnswered(answer: "Theirs", answeredBy: .caller, answeredAt: time.timeIntervalSince1970))
        // then
        let stamp = time.formatted(date: .abbreviated, time: .shortened)
        #expect(state(sut)?.phase == .settled(title: "Already answered by the caller", lines: ["Theirs", stamp, "Your saved draft", "Mine"], action: .none))
        #expect(state(sut)?.draft == "Mine")
    }

    @Test func givenTruncatedAnswerByHarflow_whenFinished_thenExcerptPrefixAndHarflowTitle() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        // when
        await submit(sut, feed: feed, draft: "x", outcome: .alreadyAnswered(answer: "Long", answeredBy: .monitor, answeredAt: 0, answerTruncated: true))
        // then
        guard case .settled(let title, let lines, .none)? = state(sut)?.phase else { Issue.record("expected settled"); return }
        #expect(title == "Answered in Harflow" && lines.count == 4 && lines[1].hasPrefix("Answer excerpt · "))
    }

    @Test(arguments: [NeedsYouAnswerOutcome.stale("moved on"), .changed(nil)])
    func givenStaleOrChanged_whenFinished_thenSettledChangedWithOpenAndSavedDraft(outcome: NeedsYouAnswerOutcome) async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        // when
        await submit(sut, feed: feed, draft: "Mine", outcome: outcome)
        // then
        #expect(state(sut)?.phase == .settled(title: nil, lines: ["This request changed. Review it again.", "Your saved draft", "Mine"], action: .open))
    }

    @Test func givenCallerReturned_whenFinished_thenSettledWithTheMessageAndOpen() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        // when
        await submit(sut, feed: feed, draft: "Mine", outcome: .callerReturned("The caller is answering this again."))
        // then
        #expect(state(sut)?.phase == .settled(title: nil, lines: ["The caller is answering this again.", "Your saved draft", "Mine"], action: .open))
    }

    @Test func givenFailed_whenFinished_thenFieldStaysEnabledWithMessageAndCode() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        // when
        await submit(sut, feed: feed, draft: "Mine", outcome: .failed(message: "Busy", code: "session_busy", legacyText: "legacy"))
        // then
        #expect(state(sut)?.phase == .failed(message: "Busy", code: "session_busy"))
        #expect(state(sut)?.fieldEnabled == true && state(sut)?.draft == "Mine")
    }

    @Test func givenApprovalOutcome_whenFinished_thenCannotBeAnsweredHere() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        // when
        await submit(sut, feed: feed, draft: "Mine", outcome: .approvalOutcome(.uncertain))
        // then
        #expect(state(sut)?.phase == .settled(title: nil, lines: ["This request cannot be answered here."], action: .open))
    }

    @Test func givenUnknown_whenFinished_thenFieldDisabledAndDraftKept() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        // when
        await submit(sut, feed: feed, draft: "Mine", outcome: .unknown("No answer"))
        // then
        #expect(state(sut)?.phase == .unknown)
        #expect(state(sut)?.fieldEnabled == false && state(sut)?.draft == "Mine")
    }

    @Test func givenUnknown_whenAnswerTappedAgain_thenNothingIsResent() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        await submit(sut, feed: feed, draft: "Mine", outcome: .unknown("No answer"))
        // when
        sut.didEditAnswer("input:a:1", text: "Changed")
        sut.didSubmitAnswer("input:a:1")
        // then
        #expect(feed.answers.count == 1)
        #expect(state(sut)?.draft == "Mine")
    }

    // MARK: Lifetime

    @Test func givenPopoverClosed_whenReopened_thenSettledCardsAreGone() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        await submit(sut, feed: feed, draft: "Mine", outcome: .callerReturned("The caller is answering this again."))
        // when — the popover view's own lifecycle: disappear, close, appear, open.
        sut.didDisappear()
        sut.didPopoverClose()
        sut.didAppear()
        sut.didPopoverOpen()
        // then
        #expect(state(sut) == MenuBarQuestionState(draft: "Mine", phase: .editing))
    }

    @Test func givenUnknown_whenPopoverCloses_thenTheCardIsEditableAgainWithItsDraft() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        await submit(sut, feed: feed, draft: "Mine", outcome: .unknown("No answer"))
        // when
        sut.didPopoverClose()
        // then
        #expect(state(sut) == MenuBarQuestionState(draft: "Mine", phase: .editing))
    }

    @Test func givenADraft_whenPopoverClosesAndReopens_thenTheDraftRemains() {
        // given
        let (sut, _, _) = makeSUT([item()])
        sut.didEditAnswer("input:a:1", text: "Half typed")
        // when
        sut.didDisappear()
        sut.didPopoverClose()
        sut.didAppear()
        // then
        #expect(state(sut)?.draft == "Half typed")
    }

    @Test func givenADraft_whenTheItemLeavesTheSnapshot_thenTheDraftIsDropped() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        sut.didEditAnswer("input:a:1", text: "Half typed")
        // when
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: []))
        await waitUntil { (sut.needsYou?.count ?? -1) == 0 }
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: [item()]))
        await waitUntil { sut.needsYou?.count == 1 }
        // then
        #expect(state(sut)?.draft == "")
    }

    @Test func givenOpenNeedsYouTapped_whenUnknown_thenRoutesToTheItemAndOpensWindow() async {
        // given
        let (sut, feed, routing) = makeSUT([item()])
        await submit(sut, feed: feed, draft: "Mine", outcome: .unknown("No answer"))
        // when
        sut.didSelectNeedsYou("input:a:1")
        // then
        verify(routing).select(.value(.needsYou(itemID: "input:a:1"))).called(1)
        verify(routing).openWindow().called(1)
    }

    @Test func givenFivePending_whenOneAnsweredAndHeld_thenShowAllStillOffered() async {
        // given
        let items = (1 ... 5).map { item("input:a:\($0)") }
        let (sut, feed, _) = makeSUT(items)
        // when
        await submit(sut, feed: feed, draft: "Yes", id: "input:a:1", outcome: .accepted)
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: Array(items.dropFirst())))
        await waitUntil { sut.needsYou?.count == 4 }
        // then
        #expect(sut.needsYou?.rows.count == 4)
        #expect(state(sut, "input:a:1")?.isHeld == true)
        #expect(sut.needsYou?.showsShowAll == true)
    }

    @Test func givenItemSettledBeforeAcceptReturns_whenFinished_thenTheSettledRowIsStillPresent() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        feed.gated = true
        sut.didEditAnswer("input:a:1", text: "Yes")
        sut.didSubmitAnswer("input:a:1")
        await waitUntil { feed.answers.count == 1 }
        // when — the repository settles the item, then the outcome returns.
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: []))
        await waitUntil { (sut.needsYou?.count ?? -1) == 0 }
        feed.release()
        await waitUntil { state(sut)?.isHeld == true }
        // then
        #expect(sut.needsYou?.rows.count == 1)
        #expect(state(sut)?.phase == .settled(title: "Answered", lines: ["Yes", "Run input:a:1 no longer needs you."], action: .none))
    }

    @Test func givenItemLeavesMidSubmit_whenResultIsUnknown_thenTheDraftIsKept() async {
        // given
        let (sut, feed, _) = makeSUT([item()])
        feed.gated = true
        feed.outcome = .unknown("No answer")
        sut.didEditAnswer("input:a:1", text: "Mine")
        sut.didSubmitAnswer("input:a:1")
        await waitUntil { feed.answers.count == 1 }
        // when
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: []))
        await waitUntil { (sut.needsYou?.count ?? -1) == 0 }
        feed.release()
        await waitUntil { state(sut)?.phase == .unknown }
        // then
        #expect(state(sut) == MenuBarQuestionState(draft: "Mine", phase: .unknown))
    }

    // MARK: Pure mapping

    @Test func givenAnEmptyDraft_whenAlreadyAnswered_thenNoSavedDraftLines() {
        // given
        let outcome = NeedsYouAnswerOutcome.alreadyAnswered(answer: "Theirs", answeredBy: .caller, answeredAt: 0)
        // when
        let phase = MenuBarVM.phase(for: outcome, item: item(), draft: "")
        // then
        guard case .settled(_, let lines, _) = phase else { Issue.record("expected settled"); return }
        #expect(lines.count == 2 && lines[0] == "Theirs")
    }

    @Test func givenEachPhase_whenAnnounced_thenTheTextVoiceOverReadsIsExact() {
        // given / when / then
        #expect(MenuBarQuestionState(phase: .editing).announcement == nil)
        #expect(MenuBarQuestionState(phase: .submitting).announcement == "Submitting your answer to the Harflow runtime…")
        #expect(MenuBarQuestionState(phase: .unknown).announcement == "Harflow couldn't confirm your answer was received. Open Needs you to check.")
        #expect(MenuBarQuestionState(phase: .failed(message: "Busy", code: "x")).announcement == "Busy")
        #expect(MenuBarQuestionState(phase: .settled(title: "Answered", lines: ["Yes", "Done"], action: .none)).announcement == "Answered. Yes. Done")
    }
}
