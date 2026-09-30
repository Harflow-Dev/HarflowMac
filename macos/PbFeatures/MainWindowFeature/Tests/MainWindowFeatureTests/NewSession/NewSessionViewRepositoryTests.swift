import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import Testing

@MainActor
@Suite struct NewSessionViewRepositoryTests {
    
    // MARK: - Repo path validation (ported verbatim from the old `NewSessionSheet.start()`)
    
    @Test func givenARelativePath_whenValidated_thenNilIsReturned() {
        // given
        let sut = NewSessionViewRepository()
        
        // then
        #expect(sut.resolvedRepoPath("relative/path") == nil)
    }
    
    @Test func givenAnAbsolutePathToAMissingDirectory_whenValidated_thenNilIsReturned() {
        // given
        let sut = NewSessionViewRepository()
        
        // then
        #expect(sut.resolvedRepoPath("/definitely/does/not/exist/\(UUID().uuidString)") == nil)
    }
    
    @Test func givenAnAbsolutePathToAnExistingDirectory_whenValidated_thenThePathIsReturned() {
        // given
        let sut = NewSessionViewRepository()
        
        // then — `/tmp` always exists.
        #expect(sut.resolvedRepoPath("/tmp") == "/tmp")
    }
    
    @Test func givenATildePath_whenValidated_thenItIsExpandedFirst() {
        // given
        let sut = NewSessionViewRepository()
        
        // then
        #expect(sut.resolvedRepoPath("~") == NSHomeDirectory())
    }
    
    // MARK: - Delegation
    
    @Test func givenRun_whenCalled_thenItForwardsToTaskActionRepository() async throws {
        // given
        let taskAction = MockTaskActionRepository()
        let request = RunRequest(backend: "claude", repo: "/tmp", prompt: "hi")
        given(taskAction).run(.value(request)).willReturn("new-id")
        let sut = NewSessionViewRepository(taskActionRepository: taskAction)
        
        // when
        let id = try await sut.run(request)
        
        // then
        #expect(id == "new-id")
    }

    // MARK: - Backend catalog (Monitor piece 6)

    @Test func givenBackendCatalogValues_whenReadOrSubscribed_thenTheyPassThroughToBackendsRepository() {
        // given
        let backends = MockBackendsRepository()
        let catalog = BackendCatalog(entries: [BackendCatalogEntry(backend: "vibe", installed: true)], state: .available)
        given(backends).catalog.willReturn(catalog)
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        given(backends).catalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        let sut = NewSessionViewRepository(backendsRepository: backends)

        // then
        #expect(sut.backendCatalog == catalog)

        var received: BackendCatalog?
        let cancellable = sut.backendCatalogPublisher().sink { received = $0 }
        let updated = BackendCatalog(entries: [], state: .loading)
        catalogSubject.send(updated)

        // then
        #expect(received == updated)
        cancellable.cancel()
    }

    // MARK: - Task listing

    @Test func givenTasksInTheListRepository_whenReadFromTheUseCase_thenTheyPassThrough() {
        // given
        let list = MockTaskListRepository()
        let task = TaskInfo(.object(["task_id": .string("abc123"), "repo_path": .string("/tmp")]))!
        given(list).tasks.willReturn([task])
        let sut = NewSessionViewRepository(taskListRepository: list)

        // then
        #expect(sut.tasks == [task])
    }
}
