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
        init(_ snapshot: NeedsYouSnapshot) { self.subject = CurrentValueSubject(snapshot) }
        var needsYouSnapshot: NeedsYouSnapshot { subject.value }
        func needsYouSnapshotPublisher() -> AnyPublisher<NeedsYouSnapshot, Never> { subject.eraseToAnyPublisher() }
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
}
