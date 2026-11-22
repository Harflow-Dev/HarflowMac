import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Testing

// MARK: - MenuBarVM Needs you

@MainActor
@Suite struct MenuBarVMNeedsYouTests {
    private final class FakeNeedsYou: MenuBarNeedsYouUseCase {
        let subject: CurrentValueSubject<NeedsYouSnapshot, Never>
        var publishesOnBackgroundQueue = false
        var responses: [(NeedsYouItem, String)] = []
        var outcome: NeedsYouAnswerOutcome = .approvalOutcome(.uncertain)
        var refreshCount = 0
        var contextCurrent = true
        var freshReviewSucceeded = false
        var reviewCalls = 0
        func canReviewApprovalAgain(_: NeedsYouItem) async -> Bool { reviewCalls += 1; return freshReviewSucceeded }
        func isApprovalContextCurrent(_: NeedsYouItem) -> Bool { contextCurrent }
        func respondToApproval(_ item: NeedsYouItem, decision: String) async -> NeedsYouAnswerOutcome {
            responses.append((item, decision)); return outcome
        }

        func refreshNeedsYou() { refreshCount += 1 }
        init(_ snapshot: NeedsYouSnapshot) { self.subject = CurrentValueSubject(snapshot) }
        var needsYouSnapshot: NeedsYouSnapshot { subject.value }
        func needsYouSnapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> {
            let publisher = subject.eraseToAnyPublisher()
            return publishesOnBackgroundQueue ? publisher.receive(on: DispatchQueue.global(qos: .userInitiated)).eraseToAnyPublisher()
                : publisher
        }
    }

    private func item(_ id: String, ended: Bool = true) -> NeedsYouItem {
        NeedsYouItem(id: id, kind: .question, runTitle: "Run \(id)", text: "t",
                     ownership: .init(owner: "caller", callerEnded: ended, engineNote: "", handover: nil), startedBy: "Original caller")
    }

    private func makeSUT(_ snapshot: NeedsYouSnapshot) -> (sut: MenuBarVM, feed: FakeNeedsYou, routing: MockMenuBarRouting) {
        let useCase = MockMenuBarUseCase()
        let routing = MockMenuBarRouting()
        given(useCase).connectionLine.willReturn("connected")
        given(useCase).runningCount.willReturn(0)
        given(useCase).runtimeReady.willReturn(true)
        given(useCase).runtimeReadyPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(useCase).installState.willReturn(.idle)
        given(useCase).lastCheckMessage.willReturn(nil)
        given(useCase).installAnywayBlockedMessage.willReturn(nil)
        given(useCase).tasksPublisher().willReturn(Just([]).eraseToAnyPublisher())
        given(useCase).countsPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(Just(nil).eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).installStatePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).lastCheckMessagePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).installAnywayBlockedMessagePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(routing).select(.any).willReturn()
        given(routing).openWindow().willReturn()
        let feed = FakeNeedsYou(snapshot)
        let sut = MenuBarVM(useCase: useCase, routing: routing, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler(), needsYou: feed)
        return (sut, feed, routing)
    }

    @Test func givenSixRequests_whenAppeared_thenThreeRowsAndShowAllAreOffered() async {
        // given
        let items = (1 ... 6).map { item("input:a:\($0)") }
        let (sut, _, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: items))
        // when
        sut.didAppear()
        // then
        let section = sut.needsYou
        #expect(section?.label == "Needs you · 6" && section?.rows.count == 3 && section?.showsShowAll == true)
        #expect(section?.showAllTitle == "Show all 6" && section?.rows.first?.subtitle == "Ended · Original caller")
    }

    @Test func givenTwoRequests_whenAppeared_thenNoShowAll() {
        let (sut, _, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [item("input:a:1"), item("input:a:2")]))
        sut.didAppear()
        #expect(sut.needsYou?.showsShowAll == false && sut.needsYou?.rows.count == 2)
    }

    @Test func givenNothingPending_whenAppeared_thenSectionIsEmptyNotHidden() {
        let (sut, _, _) = makeSUT(NeedsYouSnapshot(phase: .ready))
        sut.didAppear()
        #expect(sut.needsYou?.rows.isEmpty == true && (sut.needsYou?.count ?? -1) == 0)
        #expect(sut.needsYou?.label == "Needs you")
    }

    @Test func givenLoading_whenAppeared_thenSectionIsHidden() {
        let (sut, _, _) = makeSUT(NeedsYouSnapshot(phase: .loading))
        sut.didAppear()
        #expect(sut.needsYou == nil)
    }

    @Test func givenUnreadableSources_whenAppeared_thenCountIsALowerBound() {
        let (sut, _, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [item("input:a:1")], unreadableSourceCount: 1))
        sut.didAppear()
        #expect(sut.needsYou?.label == "Needs you · 1" && sut.needsYou?.showAllTitle == "Show all 1")
    }

    @Test func givenOlderEngine_whenAppeared_thenNoticeIsFlagged() {
        let (sut, _, _) = makeSUT(NeedsYouSnapshot(phase: .ready, workflowInputsUnsupported: true))
        sut.didAppear()
        #expect(sut.needsYou?.olderEngine == true)
    }

    @Test func givenRowAndShowAll_whenTapped_thenRoutingSelectsAndOpensTheWindow() {
        // given
        let (sut, _, routing) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [item("input:a:1")]))
        // when
        sut.didSelectNeedsYou("input:a:1")
        sut.didTapShowAllNeedsYou()
        // then
        verify(routing).select(.value(.needsYou(itemID: "input:a:1"))).called(1)
        verify(routing).select(.value(.needsYou(itemID: nil))).called(1)
        verify(routing).openWindow().called(2)
    }

    @Test func givenPopoverClosedAndReopened_whenSnapshotsChange_thenSubscriptionIsReleasedAndRestored() async {
        // given
        let (sut, feed, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [item("input:a:1")]))
        sut.didAppear()
        sut.didAppear()
        // when
        sut.didDisappear()
        sut.didDisappear()
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: [item("input:a:1"), item("input:a:2")]))
        #expect(sut.needsYou?.count == 1)
        sut.didAppear()
        await waitUntil { sut.needsYou?.count == 2 }
        // then
        #expect(sut.needsYou?.count == 2)
    }

    @Test func givenBackgroundSnapshotPublisher_whenNeedsYouChanges_thenSectionUpdatesOnMainActor() async {
        // given
        let (sut, feed, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [item("input:a:1")]))
        feed.publishesOnBackgroundQueue = true
        sut.didAppear()

        // when
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: [item("input:a:2")]))
        await waitUntil { sut.needsYou?.rows.first?.id == "input:a:2" }

        // then
        #expect(sut.needsYou?.count == 1)
        #expect(sut.needsYou?.rows.first?.title == "Run input:a:2")
        sut.didDisappear()
    }
}

extension MenuBarVMNeedsYouTests {
    private func approvalItem() -> NeedsYouItem {
        var value = item("approval:t:r")
        value.kind = .approval
        value.approval = CallerApprovalRequest(raw: ["request_id": .string("r"), "task_id": .string("t"), "action_digest": .string("digest")])
        value.approvalContext = ApprovalResponseContext(
            runtime: QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:])), epoch: UUID()
        )
        return value
    }

    @Test func givenExactDisplayedApproval_whenMenuActionRuns_thenCapturedItemAndDecisionReachSharedUseCase() async throws {
        // given
        let item = approvalItem()
        let (sut, feed, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [item]))
        sut.didAppear()
        let row = try #require(sut.needsYou?.rows.first)
        // when
        sut.didDecideApproval(row, decision: "approve")
        await waitUntil { feed.responses.count == 1 && sut.needsYou?.rows.first?.canDecide == false }
        sut.didDecideApproval(row, decision: "reject")
        // then
        #expect(feed.responses.count == 1)
        #expect(feed.responses.first?.0 == item && feed.responses.first?.1 == "approve")
        #expect(sut.needsYou?.rows.first?.resultLines == ["Delivery is unknown. The decision will not be retried."])
    }

    @Test func givenDisplayedMenuRowIsReplaced_whenOldClosureRuns_thenNoResponseRuns() async throws {
        // given
        let item = approvalItem()
        let (sut, feed, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [item]))
        sut.didAppear()
        let old = try #require(sut.needsYou?.rows.first)
        var changed = item
        changed.text = "A different exact action"
        // when
        feed.subject.send(NeedsYouSnapshot(phase: .ready, items: [changed]))
        await waitUntil { sut.needsYou?.rows.first?.item?.text == changed.text }
        sut.didDecideApproval(old, decision: "approve")
        // then
        #expect(feed.responses.isEmpty)
    }

    @Test func givenNotCurrentMenuResponse_whenRefreshIsTapped_thenOnlyReadOnlyRefreshRuns() async throws {
        // given
        let (sut, feed, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [approvalItem()]))
        feed.outcome = .approvalOutcome(.refused(
            .structuredRefusal(code: "approval_error", message: "stale", data: ["reason": .string("not_current")]), current: nil
        ))
        sut.didAppear()
        let row = try #require(sut.needsYou?.rows.first)
        // when
        sut.didDecideApproval(row, decision: "approve")
        await waitUntil { sut.needsYou?.rows.first?.showsRefresh == true }
        sut.didRefreshApprovals()
        // then
        #expect(feed.responses.count == 1)
        #expect(feed.refreshCount == 1)
        #expect(sut.needsYou?.rows.first?.canDecide == false)
        #expect(sut.needsYou?.count == 1)
    }
}

extension MenuBarVMNeedsYouTests {
    @Test func givenOtherSurfaceBusyThenPreflightFails_whenMenuReprojects_thenBusyDoesNotBecomePermanentLocalResult() async throws {
        // given
        let (sut, feed, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [approvalItem()]))
        feed.outcome = .approvalOutcome(.busy)
        sut.didAppear()
        let row = try #require(sut.needsYou?.rows.first)
        // when
        sut.didDecideApproval(row, decision: "approve")
        await waitUntil { feed.responses.count == 1 && sut.approvalSubmitting.isEmpty }
        sut.updateNeedsYou(feed.needsYouSnapshot) // Shared owner no longer holds admission.
        // then
        #expect(sut.approvalResults[row.id] == nil)
        #expect(sut.needsYou?.rows.first?.canDecide == true)
        #expect(feed.responses.count == 1)
    }
}

extension MenuBarVMNeedsYouTests {
    @Test func givenNeverInvokedCapabilityFailure_whenExplicitFreshReviewSucceeds_thenSameIdentityMenuActionsRecoverWithoutRespondingAgain() async throws {
        // given
        let (sut, feed, _) = makeSUT(NeedsYouSnapshot(phase: .ready, items: [approvalItem()]))
        feed.outcome = .approvalOutcome(.refused(.structuredRefusal(code: "approval_error", message: "unsupported",
                                                                  data: ["reason": .string("unsupported")]), current: nil))
        sut.didAppear()
        let row = try #require(sut.needsYou?.rows.first)
        sut.didDecideApproval(row, decision: "approve")
        await waitUntil { sut.needsYou?.rows.first?.showsRefresh == true }
        // when
        sut.didRefreshApprovals()
        await waitUntil { feed.reviewCalls == 1 }
        #expect(sut.needsYou?.rows.first?.canDecide == false)
        feed.freshReviewSucceeded = true
        sut.didRefreshApprovals()
        await waitUntil { sut.needsYou?.rows.first?.canDecide == true }
        // then
        #expect(feed.responses.count == 1)
        #expect(feed.reviewCalls == 2)
        #expect(sut.approvalResults[row.id] == nil)
    }
}
