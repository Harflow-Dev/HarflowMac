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
}
