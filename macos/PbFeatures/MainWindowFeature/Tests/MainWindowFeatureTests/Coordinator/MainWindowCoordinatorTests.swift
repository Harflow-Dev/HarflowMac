import AppKit
import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbCommonTestMock
import Testing

@MainActor
@Suite struct MainWindowCoordinatorTests {
    
    // MARK: - handle(path:)
    
    @Test func givenATaskDestination_whenHandled_thenSelectionIsSetAndNothingBubbles() {
        // given
        let parent = MockCoordinator()
        given(parent).handle(path: .any).willReturn()
        let sut = MainWindowCoordinator(parent: parent)
        
        // when
        sut.handle(path: MonitorDestination.task("abc123"))
        
        // then
        #expect(sut.selection == .task("abc123"))
        verify(parent).handle(path: .any).called(0)
    }
    
    @Test func givenAGroupDestination_whenHandled_thenSelectionIsSet() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        
        // when
        sut.handle(path: MonitorDestination.group("release-notes"))
        
        // then
        #expect(sut.selection == .group("release-notes"))
    }
    
    @Test func givenANewSessionDestination_whenHandled_thenTheSheetIsPresented() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        
        // when
        sut.handle(path: MonitorDestination.newSession)
        
        // then
        #expect(sut.isNewSessionPresented)
    }
    
    @Test func givenAnOpenWindowDestination_whenHandled_thenItBubblesToTheParent() {
        // given — `any PathDestination` has no registered `Matcher` comparator, so `.value(...)`
        // crashes on `verify`; capture the bubbled path via `willProduce` instead (same pattern as
        // `SettingsCoordinatorTests`).
        let parent = MockCoordinator()
        var captured: (any PathDestination)?
        given(parent)
            .handle(path: .any)
            .willProduce { captured = $0 }
        let sut = MainWindowCoordinator(parent: parent)
        
        // when
        sut.handle(path: MonitorDestination.openWindow)
        
        // then
        #expect(captured?.pathId == MonitorDestination.openWindow.pathId)
        #expect(sut.selection == nil)
    }
    
    @Test func givenADestinationOutsideMonitorDestination_whenHandled_thenItBubblesToTheParent() {
        // given
        struct OtherDestination: PathDestination { var pathId: String { "other" } }
        let parent = MockCoordinator()
        given(parent).handle(path: .any).willReturn()
        let sut = MainWindowCoordinator(parent: parent)
        
        // when
        sut.handle(path: OtherDestination())
        
        // then
        verify(parent).handle(path: .any).called(1)
    }
    
    // MARK: - Selection publisher (read by `AppCoordinator`/`SidebarRouting` for the current selection)
    
    @Test func givenSelectionChanges_whenObserved_thenThePublisherEmitsOnlyOnRealChanges() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        var received: [MonitorDestination?] = []
        let cancellable = sut.selectionPublisher().sink { received.append($0) }
        #expect(received == [nil])
        
        // when
        sut.selection = .task("abc123")
        sut.selection = .task("abc123") // no change — must not emit again
        sut.selection = .group("abc123") // complete destination equality, not identifier-only
        sut.selection = .task("abc123") // returning to a previous state must emit
        sut.selection = nil
        sut.selection = nil
        
        // then
        #expect(received == [nil, .task("abc123"), .group("abc123"), .task("abc123"), nil])
        cancellable.cancel()
    }
    
    @Test func givenIsNewSessionPresentedChanges_whenObserved_thenThePublisherEmitsOnlyOnRealChanges() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        var received: [Bool] = []
        let cancellable = sut.isNewSessionPresentedPublisher().sink { received.append($0) }
        #expect(received == [false])
        
        // when
        sut.isNewSessionPresented = true
        sut.isNewSessionPresented = true
        sut.isNewSessionPresented = false
        sut.isNewSessionPresented = false
        sut.isNewSessionPresented = true
        
        // then
        #expect(received == [false, true, false, true])
        cancellable.cancel()
    }

    @Test func givenStateChangesBeforeSubscription_whenSubscribed_thenEachPublisherReplaysTheLatestState() {
        // given
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        let selectionPublisher = sut.selectionPublisher()
        let sheetPublisher = sut.isNewSessionPresentedPublisher()
        sut.selection = .workflowRun("current-run")
        sut.isNewSessionPresented = true
        var selections: [MonitorDestination?] = []
        var presentations: [Bool] = []
        // when
        let selectionToken = selectionPublisher.sink { selections.append($0) }
        let sheetToken = sheetPublisher.sink { presentations.append($0) }
        // then — replay is subscription-time state, not a getter-time captured default.
        #expect(selections == [.workflowRun("current-run")])
        #expect(presentations == [true])
        selectionToken.cancel()
        sheetToken.cancel()
    }
    
    // MARK: - SidebarRouting
    
    @Test func givenSidebarSelect_whenCalled_thenSelectionIsSet() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        
        // when
        sut.select(.group("g1"))
        
        // then
        #expect(sut.selection == .group("g1"))
    }
    
    @Test func givenSidebarSelectNil_whenCalled_thenSelectionClears() {
        // given — `List(selection:)` writes `nil` on deselection; the old
        // `List(selection: $model.selection)` accepted that directly (Codex review finding).
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        sut.select(.task("abc123"))
        // Positive setup first: the initial select really took effect, so clearing it below proves
        // something, rather than matching a coordinator whose `select` never did anything.
        #expect(sut.selection == .task("abc123"))
        
        // when
        sut.select(nil)
        
        // then
        #expect(sut.selection == nil)
    }
    
    @Test func givenSidebarOpenNewSession_whenCalled_thenTheSheetIsPresented() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        
        // when
        sut.openNewSession()
        
        // then
        #expect(sut.isNewSessionPresented)
    }
    
    // MARK: - NewSessionRouting
    
    @Test func givenDidStart_whenCalled_thenSelectionIsSetAndTheSheetDismisses() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        sut.isNewSessionPresented = true
        
        // when
        sut.didStart(taskID: "abc123")
        
        // then
        #expect(sut.selection == .task("abc123"))
        #expect(sut.isNewSessionPresented == false)
    }
    
    @Test func givenDismiss_whenCalled_thenTheSheetIsDismissedWithoutTouchingSelection() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        sut.isNewSessionPresented = true
        sut.selection = .task("abc123")
        
        // when
        sut.dismiss()
        
        // then
        #expect(sut.isNewSessionPresented == false)
        #expect(sut.selection == .task("abc123"))
    }
    
    // MARK: - Building views
    
    @Test func givenTheCoordinator_whenBuildingSidebarAndNewSessionViews_thenBothViewsAreProduced() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        
        // then — must not crash; `buildSidebarView` shares one VM, `buildNewSessionView` builds fresh.
        _ = sut.buildSidebarView()
        _ = sut.buildSidebarView()
        _ = sut.buildNewSessionView()
        _ = sut.start()
    }
    
    @Test func givenTheCoordinator_whenBuildingAParallelView_thenAViewIsProduced() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        
        // then — must not crash.
        _ = sut.buildParallelView(name: "release-notes")
    }
    
    @Test func givenTheCoordinator_whenBuildingATaskDetailView_thenAViewIsProduced() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)

        // then — must not crash.
        _ = sut.buildTaskDetailView(id: "abc123")
    }

    // MARK: - ParallelRouting / TaskDetailRouting
    
    @Test func givenParallelSelectTask_whenCalled_thenSelectionIsSetToThatTask() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        
        // when
        sut.selectTask("abc123")
        
        // then
        #expect(sut.selection == .task("abc123"))
    }
    
    @Test func givenTaskDetailSelectTask_whenCalled_thenSelectionIsSetToThatTask() {
        // given — `TaskDetailRouting.selectTask(_:)` is satisfied by the same implementation as
        // `ParallelRouting.selectTask(_:)` (identical requirement), verified here as its own
        // protocol conformance rather than assumed from the Parallel test above.
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        let routing: any TaskDetailRouting = sut

        // when
        routing.selectTask("def456")

        // then
        #expect(sut.selection == .task("def456"))
    }

    // MARK: - TaskDetailRouting.copyToPasteboard (Monitor piece 3/3, pasteboard seam)

    @MainActor
    final class FakePasteboard: PasteboardWriting {
        /// Every call in order, so a test can tell clear-then-write from write-then-clear (which
        /// would leave the real clipboard empty) and see the pasteboard type used.
        private(set) var calls: [String] = []
        var setStringResult = true

        func clearContents() -> Int {
            calls.append("clear")
            return 0
        }

        func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
            calls.append("set[\(dataType.rawValue)]:\(string)")
            return setStringResult
        }
    }

    @Test func givenCopyToPasteboardSucceeds_whenCalled_thenTheRealClipboardIsNeverTouched() {
        // given — the injectable seam is what makes this test possible at all: a coordinator built
        // with the default initializer would reach `NSPasteboard.general`.
        let fake = FakePasteboard()
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent, pasteboard: fake)
        let routing: any TaskDetailRouting = sut

        // when
        let succeeded = routing.copyToPasteboard("cd /repo && claude --resume s")

        // then
        #expect(succeeded)
        #expect(fake.calls == ["clear", "set[\(NSPasteboard.PasteboardType.string.rawValue)]:cd /repo && claude --resume s"])
    }

    @Test func givenCopyToPasteboardFails_whenCalled_thenFalseIsReturned() {
        // given
        let fake = FakePasteboard()
        fake.setStringResult = false
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent, pasteboard: fake)
        let routing: any TaskDetailRouting = sut

        // when
        let succeeded = routing.copyToPasteboard("cd /repo && claude --resume s")

        // then
        #expect(!succeeded)
    }

    // MARK: - Pending reveal (piece 4), against the real coordinator

    @Test func givenTwoNavigationRequestsForTheSameTask_whenHandled_thenEachGetsAFreshRequestAndOnlyTheLatestIsPending() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        var published: [PendingReveal] = []
        let cancellable = sut.revealPublisher().sink { published.append($0) }
        var selections: [MonitorDestination?] = []
        let selectionToken = sut.selectionPublisher().sink { selections.append($0) }

        // when
        sut.handle(path: MonitorDestination.task("child"))
        let first = sut.pendingReveal
        sut.handle(path: MonitorDestination.task("child"))
        let second = sut.pendingReveal
        cancellable.cancel()
        selectionToken.cancel()

        // then — a repeat is a new request (so it reveals again), and both were published
        #expect(first?.taskID == "child")
        #expect(second?.taskID == "child")
        #expect(first?.requestID != second?.requestID)
        #expect(published.map(\.requestID) == [first?.requestID, second?.requestID].compactMap(\.self))
        #expect(selections == [nil, .task("child")])
    }

    @Test func givenASupersededRequest_whenItIsConsumed_thenTheNewerRequestStaysPendingUntilItIsConsumed() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        sut.handle(path: MonitorDestination.task("a"))
        let old = sut.pendingReveal!
        sut.handle(path: MonitorDestination.task("b"))
        let newer = sut.pendingReveal!

        // when / then — consuming the stale id is a no-op...
        sut.consumeReveal(requestID: old.requestID)
        #expect(sut.pendingReveal?.requestID == newer.requestID)
        // ...and the current one is consumed exactly once.
        sut.consumeReveal(requestID: newer.requestID)
        #expect(sut.pendingReveal == nil)
    }

    @Test func givenTheSidebarsOwnSelection_whenMade_thenNoRevealIsRequested() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        let routing: any SidebarRouting = sut

        // when
        routing.select(.task("row-the-user-clicked"))

        // then
        #expect(sut.pendingReveal == nil)
        #expect(sut.selection == .task("row-the-user-clicked"))
    }
}
