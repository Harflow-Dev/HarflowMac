import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTerminal
import Testing

@MainActor
@Suite struct SidebarViewRepositoryTests {
    
    @Test func givenTheProperties_whenRead_thenTheyPassThroughToTaskListRepository() {
        // given
        let taskList = MockTaskListRepository()
        given(taskList).tasks.willReturn([])
        given(taskList).listError.willReturn(nil)
        given(taskList).hasListed.willReturn(true)
        given(taskList).connectionLine.willReturn("connected")
        given(taskList).title(.value("abc123")).willReturn("Fix the bug")
        let sut = SidebarViewRepository(taskListRepository: taskList)
        
        // then
        #expect(sut.tasks.isEmpty)
        #expect(sut.listError == nil)
        #expect(sut.hasListed)
        #expect(sut.connectionLine == "connected")
        #expect(sut.title("abc123") == "Fix the bug")
    }
    
    @Test func givenThePublishers_whenSubscribed_thenTheyForwardTaskListValues() {
        // given
        let taskList = MockTaskListRepository()
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        given(taskList).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
        given(taskList).listErrorPublisher().willReturn(Just(nil).eraseToAnyPublisher())
        given(taskList).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
        let sut = SidebarViewRepository(taskListRepository: taskList)
        var received: [TaskInfo]?
        let cancellable = sut.tasksPublisher().sink { received = $0 }
        
        // when
        let task = TaskInfo(.object(["task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running")]))!
        tasksSubject.send([task])
        
        // then
        #expect(received == [task])
        cancellable.cancel()
    }
    
    @Test func givenTitlesPublisher_whenSubscribed_thenItForwardsTaskListTitles() {
        // given — F4-11/MS-LIST-5: titles load off-main separately from the listing, so this
        // publisher has to exist and forward independently of `tasksPublisher`.
        let taskList = MockTaskListRepository()
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        given(taskList).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
        let sut = SidebarViewRepository(taskListRepository: taskList)
        var received: [String: String]?
        let cancellable = sut.titlesPublisher().sink { received = $0 }
        
        // when
        titlesSubject.send(["abc123": "Fix the bug"])
        
        // then
        #expect(received == ["abc123": "Fix the bug"])
        cancellable.cancel()
    }
    
    @Test func givenSessionQueries_whenCalled_thenTheyForwardToTheSessionRegistry() {
        // given
        let registry = MockTerminalSessionRegistry()
        given(registry).session(forTask: .value("abc123")).willReturn(nil)
        given(registry).interactiveSessions.willReturn([])
        given(registry).sessionsPublisher().willReturn(Just([]).eraseToAnyPublisher())
        let sut = SidebarViewRepository(terminalSessionRegistry: registry)
        
        // then
        #expect(sut.session(forTask: "abc123") == nil)
        #expect(sut.interactiveSessions.isEmpty)
        verify(registry).session(forTask: .value("abc123")).called(1)
    }
}
