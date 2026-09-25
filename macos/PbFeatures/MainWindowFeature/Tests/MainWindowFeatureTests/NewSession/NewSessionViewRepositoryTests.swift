import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTerminal
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
    
    @Test func givenStartInteractive_whenCalled_thenItForwardsToTheSessionRegistryWithTheResolvedEnvironment() throws {
        // given
        let registry = MockTerminalSessionRegistry()
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).environment(toolDirectory: .value(nil)).willReturn(["PATH": "/usr/bin"])
        let session = TerminalSession(
            kind: .interactive, title: "t", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        given(registry)
            .startInteractive(
                backend: .value("claude"), repo: .value("/tmp"), environment: .value(["PATH": "/usr/bin"])
            )
            .willReturn(.success(session))
        let sut = NewSessionViewRepository(terminalSessionRegistry: registry, toolEnvironmentRepository: toolEnvironment)
        
        // when
        let result = sut.startInteractive(backend: "claude", repo: "/tmp")
        
        // then
        if case .success(let started) = result {
            #expect(started === session)
        } else {
            Issue.record("expected success")
        }
    }
}
