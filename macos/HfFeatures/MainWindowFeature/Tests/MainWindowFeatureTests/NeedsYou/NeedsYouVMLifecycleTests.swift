import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - GatedUseCase

/// A use case whose answers wait for the test, so completions can be ordered against navigation.
@MainActor
private final class GatedUseCase: NeedsYouUseCase {
    let subject: CurrentValueSubject<NeedsYouSnapshot, Never>
    private var continuations: [String: CheckedContinuation<NeedsYouAnswerOutcome, Never>] = [:]
    private(set) var started: [String] = []
    private(set) var refreshes = 0

    init(_ snapshot: NeedsYouSnapshot) { self.subject = CurrentValueSubject(snapshot) }

    var snapshot: NeedsYouSnapshot { subject.value }
    func snapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { subject.eraseToAnyPublisher() }
    func refresh() { refreshes += 1 }

    func answer(_ item: NeedsYouItem, text _: String, additionalAttempts _: Int?) async -> NeedsYouAnswerOutcome {
        started.append(item.id)
        return await withCheckedContinuation { continuations[item.id] = $0 }
    }

    func respond(_ item: NeedsYouItem, decision _: String) async -> NeedsYouAnswerOutcome { await answer(item, text: "", additionalAttempts: nil) }

    func complete(_ id: String, _ outcome: NeedsYouAnswerOutcome) { continuations.removeValue(forKey: id)?.resume(returning: outcome) }
}

private final class Routed: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String?] = []
    var all: [String?] { lock.withLock { values } }
    func add(_ value: String?) { lock.withLock { values.append(value) } }
}

// MARK: - NeedsYouVMLifecycleTests

@MainActor
@Suite struct NeedsYouVMLifecycleTests {
    private func item(_ id: String) -> NeedsYouItem {
        NeedsYouItem(id: id, kind: .question, rootRunID: "w", sourceRunID: "w", runTitle: "Run \(id)", pathTitles: ["Run"], text: "Q \(id)",
                     ownership: .init(owner: "caller", callerEnded: true, engineNote: "", handover: nil),
                     startedBy: "Original caller", waitingSince: Date(timeIntervalSince1970: 100), decisionID: "d-\(id)")
    }

    private func rig(_ snapshot: NeedsYouSnapshot) -> (sut: NeedsYouVM, useCase: GatedUseCase, routed: Routed) {
        let useCase = GatedUseCase(snapshot)
        let routing = MockNeedsYouRouting()
        let routed = Routed()
        given(routing).showNeedsYou(itemID: .any).willProduce { routed.add($0) }
        let sut = NeedsYouVM(useCase: useCase, routing: routing)
        sut.didChangeReduceMotion(true)
        return (sut, useCase, routed)
    }

    @Test func givenAnswerForAInFlight_whenReviewerMovesToBAndTypes_thenACompletionLeavesBUntouched() async {
        // given
        let first = item("input:w:a"), second = item("input:w:b")
        let (sut, useCase, _) = rig(NeedsYouSnapshot(phase: .ready, items: [first, second]))
        sut.didAppear()
        sut.show(itemID: first.id)
        await waitUntil { sut.displayedItem == first }
        sut.answerText = "answer for A"
        sut.didSubmitAnswer()
        await waitUntil { useCase.started == [first.id] }
        // when
        sut.show(itemID: second.id)
        await waitUntil { sut.displayedItem == second }
        sut.answerText = "draft for B"
        useCase.complete(first.id, .failed("engine said no"))
        await waitUntil { sut.submittingIDs.isEmpty }
        // then
        #expect(sut.answerText == "draft for B")
        #expect(sut.sendError == nil && sut.presentation.detail?.id == second.id && sut.presentation.detail?.error == nil)
        #expect(sut.presentation.detail?.phase == .answerable)
    }

    @Test func givenAcceptedAnswerForAWhileOnB_whenReviewerReturnsToA_thenTheSettledCardShowsNotAnExpiredOne() async {
        // given
        let first = item("input:w:a"), second = item("input:w:b")
        let (sut, useCase, _) = rig(NeedsYouSnapshot(phase: .ready, items: [first, second]))
        sut.didAppear()
        sut.show(itemID: first.id)
        await waitUntil { sut.displayedItem == first }
        sut.answerText = "yes"
        sut.didSubmitAnswer()
        await waitUntil { useCase.started == [first.id] }
        sut.show(itemID: second.id)
        sut.answerText = "draft for B"
        // when
        useCase.subject.send(NeedsYouSnapshot(phase: .ready, items: [second]))
        useCase.complete(first.id, .accepted)
        await waitUntil { sut.settled[first.id] != nil }
        sut.show(itemID: first.id)
        await waitUntil { if case .settled? = sut.presentation.detail?.phase { true } else { false } }
        // then
        guard case .settled(_, let answer, _)? = sut.presentation.detail?.phase else {
            Issue.record("expected the settled card for A")
            return
        }
        #expect(answer == "yes")
    }

    @Test func givenCallerReturnedForAWhileOnB_whenItCompletes_thenThereIsNoRedirectAndNoNotice() async {
        // given
        let first = item("input:w:a"), second = item("input:w:b")
        let (sut, useCase, routed) = rig(NeedsYouSnapshot(phase: .ready, items: [first, second]))
        sut.didAppear()
        sut.show(itemID: first.id)
        await waitUntil { sut.displayedItem == first }
        sut.answerText = "x"
        sut.didSubmitAnswer()
        await waitUntil { useCase.started == [first.id] }
        sut.show(itemID: second.id)
        await waitUntil { sut.displayedItem == second }
        sut.answerText = "draft for B"
        // when
        useCase.complete(first.id, .callerReturned("The caller is answering this again."))
        await waitUntil { sut.submittingIDs.isEmpty }
        // then
        #expect(routed.all.isEmpty)
        #expect(sut.presentation.notice == nil && sut.presentation.showsDetail && sut.answerText == "draft for B")
    }

    @Test func givenCompletionAfterTheScreenDisappeared_whenItArrives_thenNoUIStateChanges() async {
        // given
        let first = item("input:w:a")
        let (sut, useCase, routed) = rig(NeedsYouSnapshot(phase: .ready, items: [first]))
        sut.didAppear()
        sut.show(itemID: first.id)
        await waitUntil { sut.displayedItem == first }
        sut.answerText = "x"
        sut.didSubmitAnswer()
        await waitUntil { useCase.started == [first.id] }
        // when
        sut.didDisappear()
        useCase.complete(first.id, .callerReturned("The caller is answering this again."))
        await waitUntil { sut.submittingIDs.isEmpty }
        // then
        #expect(routed.all.isEmpty && sut.sendError == nil)
        #expect(sut.answerText == "x")
    }

    @Test func givenAnotherRequestSubmitting_whenReviewerAnswersB_thenBIsNotBlocked() async {
        // given
        let first = item("input:w:a"), second = item("input:w:b")
        let (sut, useCase, _) = rig(NeedsYouSnapshot(phase: .ready, items: [first, second]))
        sut.didAppear()
        sut.show(itemID: first.id)
        await waitUntil { sut.displayedItem == first }
        sut.answerText = "a"
        sut.didSubmitAnswer()
        await waitUntil { useCase.started == [first.id] }
        sut.show(itemID: second.id)
        await waitUntil { sut.displayedItem == second }
        sut.answerText = "b"
        // when
        sut.didSubmitAnswer()
        // then
        await waitUntil { useCase.started == [first.id, second.id] }
        #expect(useCase.started == [first.id, second.id])
        useCase.complete(first.id, .accepted)
        useCase.complete(second.id, .accepted)
    }

    @Test func givenSelectedRequestWithdrawn_whenSnapshotHidesIt_thenItKeepsItsDetailDisabledWithRetryNotExpired() async {
        // given
        let first = item("input:w:a")
        let (sut, useCase, _) = rig(NeedsYouSnapshot(phase: .ready, items: [first]))
        sut.didAppear()
        sut.show(itemID: first.id)
        await waitUntil { sut.presentation.detail?.phase == .answerable }
        // when — the source became unreadable: hidden from the list, but not resolved.
        useCase.subject.send(NeedsYouSnapshot(phase: .ready, items: [], unreadableSourceCount: 1, withdrawn: [first]))
        await waitUntil { sut.presentation.detail?.phase == .withdrawn }
        // then
        #expect(sut.presentation.detail?.title == "Run \(first.id)")
        sut.answerText = "try"
        sut.didSubmitAnswer()
        #expect(useCase.started.isEmpty)
        sut.didTapRetry()
        #expect(useCase.refreshes >= 2)
        // and authoritative resolution afterwards is the expired card
        useCase.subject.send(NeedsYouSnapshot(phase: .ready, items: []))
        await waitUntil { sut.presentation.detail?.phase == .expired }
        #expect(sut.presentation.detail?.phase == .expired)
    }
}
