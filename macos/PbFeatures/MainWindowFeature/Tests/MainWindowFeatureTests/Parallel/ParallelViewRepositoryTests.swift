import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
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

    @Test func givenSetOutcome_whenCalled_thenItForwardsToTaskActionRepository() {
        // given
        let actions = MockTaskActionRepository()
        given(actions).setOutcome(.value("abc123"), .value("moved on")).willReturn()
        let sut = ParallelViewRepository(taskActionRepository: actions)

        // when
        sut.setOutcome("abc123", "moved on")

        // then
        verify(actions).setOutcome(.value("abc123"), .value("moved on")).called(1)
    }
    
    @Test func givenTitlesPublisher_whenSubscribed_thenItForwardsTaskListTitles() {
        // given — F4-11/MS-LIST-5 sibling for Parallel (Codex review finding, round 1): titles load
        // independently of the listing, so a column needs this directly.
        let taskList = MockTaskListRepository()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        given(taskList).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        let sut = ParallelViewRepository(taskListRepository: taskList)
        var receivedTitles: [String: String]?
        let titlesCancellable = sut.titlesPublisher().sink { receivedTitles = $0 }

        // when
        titlesSubject.send(["abc123": "Fix the bug"])

        // then
        #expect(receivedTitles == ["abc123": "Fix the bug"])
        titlesCancellable.cancel()
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
    
    @Test func givenEventsAvailabilityQueries_whenCalled_thenTheyForwardToEventStreamRepository() {
        // given — Monitor piece 12, Design point 4: mirrors `TaskDetailViewRepositoryTests`'s
        // identical case for `TaskDetailUseCase`.
        let events = MockEventStreamRepository()
        given(events).eventsAvailability(for: .value("abc123")).willReturn(.available)
        given(events).eventsAvailabilityPublisher(for: .value("abc123")).willReturn(Just(EventAvailability.available).eraseToAnyPublisher())
        let sut = ParallelViewRepository(eventStreamRepository: events)

        // when / then
        #expect(sut.eventsAvailability(for: "abc123") == .available)
        verify(events).eventsAvailability(for: .value("abc123")).called(1)
        verify(events).eventsAvailabilityPublisher(for: .value("abc123")).called(0)
        _ = sut.eventsAvailabilityPublisher(for: "abc123")
        verify(events).eventsAvailabilityPublisher(for: .value("abc123")).called(1)
    }

    @Test func givenBeginTakeover_whenCalled_thenItForwardsToTheTakeoverService() {
        // given
        let takeover = MockTakeoverService()
        given(takeover).beginTakeover(taskID: .value("abc123")).willReturn()
        let sut = ParallelViewRepository(takeoverService: takeover)

        // when
        sut.beginTakeover(taskID: "abc123")

        // then
        verify(takeover).beginTakeover(taskID: .value("abc123")).called(1)
    }
}
