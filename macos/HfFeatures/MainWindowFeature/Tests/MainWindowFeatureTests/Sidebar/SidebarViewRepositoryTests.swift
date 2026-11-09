import Combine
import Foundation
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
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
    
    // MARK: - Backend catalog (Monitor piece 6)

    @Test func givenBackendCatalogValues_whenReadOrSubscribed_thenTheyPassThroughToBackendsRepository() {
        // given
        let backends = MockBackendsRepository()
        let catalog = BackendCatalog(entries: [BackendCatalogEntry(backend: "claude", installed: true)], state: .available)
        given(backends).catalog.willReturn(catalog)
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        given(backends).catalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        let sut = SidebarViewRepository(backendsRepository: backends)

        // then — the synchronous snapshot passes through.
        #expect(sut.backendCatalog == catalog)

        // when — so does the publisher.
        var received: BackendCatalog?
        let cancellable = sut.backendCatalogPublisher().sink { received = $0 }
        let updated = BackendCatalog(entries: [], state: .degraded)
        catalogSubject.send(updated)

        // then
        #expect(received == updated)
        cancellable.cancel()
    }
}
