import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTerminal
import Testing

@MainActor
@Suite struct ParallelViewRepositoryTests {
    
    @Test func givenTaskListQueries_whenCalled_thenTheyForwardToTaskListRepository() {
        // given
        let taskList = MockTaskListRepository()
        given(taskList).task(.value("abc123")).willReturn(nil)
        given(taskList).title(.value("abc123")).willReturn("Fix the bug")
        given(taskList).runningInSubtrees(of: .value(["abc123"])).willReturn(["abc123"])
        let sut = ParallelViewRepository(taskListRepository: taskList)
        
        // then
        #expect(sut.task("abc123") == nil)
        #expect(sut.title("abc123") == "Fix the bug")
        #expect(sut.runningInSubtrees(of: ["abc123"]) == ["abc123"])
        verify(taskList).task(.value("abc123")).called(1)
    }
    
    @Test func givenTasksPublisher_whenSubscribed_thenItForwardsTaskListValues() {
        // given
        let taskList = MockTaskListRepository()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        given(taskList).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        let sut = ParallelViewRepository(taskListRepository: taskList)
        var received: [TaskInfo]?
        let cancellable = sut.tasksPublisher().sink { received = $0 }
        
        // when
        let task = TaskInfo(.object(["task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running")]))!
        tasksSubject.send([task])
        
        // then
        #expect(received == [task])
        cancellable.cancel()
    }
    
    @Test func givenSnapshotsPublisher_whenSubscribed_thenItForwardsSnapshotRepositoryValues() {
        // given
        let snapshots = MockTaskSnapshotRepository()
        let snapshotsSubject = PassthroughSubject<[String: TaskInfo], Never>()
        given(snapshots).snapshotsPublisher().willReturn(snapshotsSubject.eraseToAnyPublisher())
        let sut = ParallelViewRepository(taskSnapshotRepository: snapshots)
        var received: [String: TaskInfo]?
        let cancellable = sut.snapshotsPublisher().sink { received = $0 }
        
        // when
        let task = TaskInfo(.object(["task_id": .string("abc123"), "backend": .string("claude"), "status": .string("completed")]))!
        snapshotsSubject.send(["abc123": task])
        
        // then
        #expect(received == ["abc123": task])
        cancellable.cancel()
    }
    
    @Test func givenBusyAndOutcomesPublishers_whenSubscribed_thenTheyForwardTaskActionRepositoryValues() {
        // given
        let actions = MockTaskActionRepository()
        let busySubject = PassthroughSubject<Set<String>, Never>()
        let outcomesSubject = PassthroughSubject<[String: String], Never>()
        given(actions).busyPublisher().willReturn(busySubject.eraseToAnyPublisher())
        given(actions).outcomesPublisher().willReturn(outcomesSubject.eraseToAnyPublisher())
        let sut = ParallelViewRepository(taskActionRepository: actions)
        var receivedBusy: Set<String>?
        var receivedOutcomes: [String: String]?
        let busyCancellable = sut.busyPublisher().sink { receivedBusy = $0 }
        let outcomesCancellable = sut.outcomesPublisher().sink { receivedOutcomes = $0 }
        
        // when
        busySubject.send(["abc123"])
        outcomesSubject.send(["abc123": "Refused: read-only freedom."])
        
        // then
        #expect(receivedBusy == ["abc123"])
        #expect(receivedOutcomes == ["abc123": "Refused: read-only freedom."])
        busyCancellable.cancel()
        outcomesCancellable.cancel()
    }
    
    @Test func givenCancelAll_whenCalled_thenItForwardsToTaskActionRepository() async {
        // given
        let actions = MockTaskActionRepository()
        given(actions).cancelAll(.value(["abc123", "def456"])).willReturn()
        let sut = ParallelViewRepository(taskActionRepository: actions)
        
        // when
        await sut.cancelAll(["abc123", "def456"])
        
        // then
        verify(actions).cancelAll(.value(["abc123", "def456"])).called(1)
    }
    
    @Test func givenSessionQuery_whenCalled_thenItForwardsToTheSessionRegistry() {
        // given
        let registry = MockTerminalSessionRegistry()
        given(registry).session(forTask: .value("abc123")).willReturn(nil)
        let sut = ParallelViewRepository(terminalSessionRegistry: registry)
        
        // then
        #expect(sut.session(forTask: "abc123") == nil)
        verify(registry).session(forTask: .value("abc123")).called(1)
    }
    
    @Test func givenTitlesAndSessionsPublishers_whenSubscribed_thenTheyForwardTaskListAndRegistryValues() throws {
        // given — F4-11/MS-LIST-5 sibling for Parallel (Codex review finding, round 1): titles and
        // live sessions load independently of the listing, so a column needs both of these directly.
        let taskList = MockTaskListRepository()
        let registry = MockTerminalSessionRegistry()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let sessionsSubject = PassthroughSubject<[TerminalSession], Never>()
        given(taskList).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        given(registry).sessionsPublisher().willReturn(sessionsSubject.eraseToAnyPublisher())
        let sut = ParallelViewRepository(taskListRepository: taskList, terminalSessionRegistry: registry)
        var receivedTitles: [String: String]?
        var receivedSessions: [TerminalSession]?
        let titlesCancellable = sut.titlesPublisher().sink { receivedTitles = $0 }
        let sessionsCancellable = sut.sessionsPublisher().sink { receivedSessions = $0 }
        
        // when — a non-empty session array, so a stub forwarding `Just([])` instead of the real
        // publisher (Codex review finding, round 2) would fail this rather than pass vacuously.
        let session = TerminalSession(
            kind: .takeover(taskID: "abc123"), title: "claude · repo", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        titlesSubject.send(["abc123": "Fix the bug"])
        sessionsSubject.send([session])
        
        // then
        #expect(receivedTitles == ["abc123": "Fix the bug"])
        #expect(receivedSessions?.map(\.id) == [session.id])
        titlesCancellable.cancel()
        sessionsCancellable.cancel()
    }
    
    @Test func givenEventStreamQueries_whenCalled_thenTheyForwardToEventStreamRepository() {
        // given
        let events = MockEventStreamRepository()
        let lease = MockEventStreamLease()
        given(lease).taskID.willReturn("abc123")
        given(events).acquire(.value("abc123")).willReturn(lease)
        given(events).items(for: .value("abc123")).willReturn([])
        given(events).itemsPublisher(for: .value("abc123")).willReturn(Just([]).eraseToAnyPublisher())
        given(events).prompt(for: .value("abc123")).willReturn("Fix the bug")
        let sut = ParallelViewRepository(eventStreamRepository: events)
        
        // when
        let acquired = sut.acquireEventLease("abc123")
        
        // then
        #expect(acquired.taskID == "abc123")
        #expect(sut.items(for: "abc123").isEmpty)
        #expect(sut.prompt(for: "abc123") == "Fix the bug")
    }
    
    @Test func givenBeginTakeover_whenCalled_thenItDispatchesAnEmbeddedTakeover() {
        // given — `TakeoverDestination` has no registered `Matcher` comparator, so capture it via
        // `willProduce` rather than `.value(...)` (same pattern as `MainWindowCoordinatorTests`'s
        // `openWindow` case).
        let takeover = MockTakeoverService()
        var capturedTaskID: String?
        var capturedDestination: TakeoverDestination?
        given(takeover)
            .beginTakeover(taskID: .any, destination: .any)
            .willProduce { taskID, destination in
                capturedTaskID = taskID
                capturedDestination = destination
            }
        let sut = ParallelViewRepository(takeoverService: takeover)
        
        // when
        sut.beginTakeover(taskID: "abc123")
        
        // then
        #expect(capturedTaskID == "abc123")
        if case .embedded = capturedDestination {} else { Issue.record("expected .embedded, got \(String(describing: capturedDestination))") }
    }
}
