import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbCommonTestMock
import PbTerminal
import PbTestUtilities
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
    
    @Test func givenAnInteractiveDestination_whenHandled_thenSelectionIsSet() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        let id = UUID()
        
        // when
        sut.handle(path: MonitorDestination.interactive(id))
        
        // then
        #expect(sut.selection == .interactive(id))
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
        
        // when
        sut.selection = .task("abc123")
        sut.selection = .task("abc123") // no change — must not emit again
        sut.selection = nil
        
        // then
        #expect(received == [.task("abc123"), nil])
        cancellable.cancel()
    }
    
    @Test func givenIsNewSessionPresentedChanges_whenObserved_thenThePublisherEmitsOnlyOnRealChanges() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        var received: [Bool] = []
        let cancellable = sut.isNewSessionPresentedPublisher().sink { received.append($0) }
        
        // when
        sut.isNewSessionPresented = true
        sut.isNewSessionPresented = true
        sut.isNewSessionPresented = false
        
        // then
        #expect(received == [true, false])
        cancellable.cancel()
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
    
    @Test func givenDidStartInteractive_whenCalled_thenSelectionIsSetAndTheSheetDismisses() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        sut.isNewSessionPresented = true
        let id = UUID()
        
        // when
        sut.didStartInteractive(sessionID: id)
        
        // then
        #expect(sut.selection == .interactive(id))
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
    
    @Test func givenTheCoordinator_whenBuildingAnInteractiveView_thenAViewIsProduced() {
        // given
        let parent = MockCoordinator()
        let sut = MainWindowCoordinator(parent: parent)
        
        // then — must not crash.
        _ = sut.buildInteractiveView(id: UUID())
    }
    
    // MARK: - Ended-session removal (moved here from the app target's `AppModel`, F4-21/F4-22)
    
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
    
    @Test func givenAnEndedInteractiveSessionThatIsSelected_whenPublished_thenItIsNotRemoved() async throws {
        // given
        let parent = MockCoordinator()
        let registry = MockTerminalSessionRegistry()
        let endedSessions = PassthroughSubject<TerminalSession, Never>()
        given(registry).endedSessionsPublisher().willReturn(endedSessions.eraseToAnyPublisher())
        let removedIDs = Box<[UUID]>([])
        given(registry).remove(.any).willProduce { removedIDs.value.append($0.id) }
        let sut = MainWindowCoordinator(parent: parent, terminalSessionRegistry: registry)
        let selected = TerminalSession(
            kind: .interactive, title: "a", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        let other = TerminalSession(
            kind: .interactive, title: "b", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        sut.selection = .interactive(selected.id)
        
        // when — the selected session ends first, then an unrelated one, proving the pipeline runs
        // at all (a vacuous "removedIDs stayed empty" would also pass if the subscription never fired).
        endedSessions.send(selected)
        endedSessions.send(other)
        
        // then
        await waitUntil { removedIDs.value.contains(other.id) }
        #expect(removedIDs.value.contains(other.id))
        #expect(!removedIDs.value.contains(selected.id))
    }
    
    @Test func givenAnEndedInteractiveSessionThatIsNotSelected_whenPublished_thenItIsRemoved() async throws {
        // given
        let parent = MockCoordinator()
        let registry = MockTerminalSessionRegistry()
        let endedSessions = PassthroughSubject<TerminalSession, Never>()
        given(registry).endedSessionsPublisher().willReturn(endedSessions.eraseToAnyPublisher())
        let removedIDs = Box<[UUID]>([])
        given(registry).remove(.any).willProduce { removedIDs.value.append($0.id) }
        let sut = MainWindowCoordinator(parent: parent, terminalSessionRegistry: registry)
        let session = TerminalSession(
            kind: .interactive, title: "a", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        sut.selection = .task("unrelated-task")
        
        // when
        endedSessions.send(session)
        
        // then
        await waitUntil { removedIDs.value.contains(session.id) }
        #expect(removedIDs.value.contains(session.id))
    }
    
    @Test func givenAnEndedTakeoverSession_whenPublished_thenItIsNeverRemovedByThisSubscription() async throws {
        // given — only `.interactive` sessions are ever auto-removed here; a take-over session's
        // lifetime is `TakeoverService`'s concern.
        let parent = MockCoordinator()
        let registry = MockTerminalSessionRegistry()
        let endedSessions = PassthroughSubject<TerminalSession, Never>()
        given(registry).endedSessionsPublisher().willReturn(endedSessions.eraseToAnyPublisher())
        let removedIDs = Box<[UUID]>([])
        given(registry).remove(.any).willProduce { removedIDs.value.append($0.id) }
        // Held for the test's duration: `subscribeToEndedSessions()`'s subscription lives in the
        // coordinator's own `cancellables`, so an unretained instance is deallocated (and its
        // subscription cancelled) the moment this statement finishes — a real bug hit while writing
        // this test, not a style nit.
        let sut = MainWindowCoordinator(parent: parent, terminalSessionRegistry: registry)
        #expect(sut.selection == nil)
        let takeover = TerminalSession(
            kind: .takeover(taskID: "abc123"), title: "a", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        let interactive = TerminalSession(
            kind: .interactive, title: "b", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        
        // when — the take-over session ends first, then an interactive one, proving the pipeline runs
        // at all.
        endedSessions.send(takeover)
        endedSessions.send(interactive)
        
        // then
        await waitUntil { removedIDs.value.contains(interactive.id) }
        #expect(removedIDs.value.contains(interactive.id))
        #expect(!removedIDs.value.contains(takeover.id))
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
}
