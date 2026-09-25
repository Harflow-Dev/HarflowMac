import Foundation
import Mockable
import MonitorCore
import PbRepository
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct HarnessesViewRepositoryTests {
    
    private func document(_ json: String) throws -> SetupDocument {
        try SetupDocument.decode(stdout: Data(json.utf8), stderr: "", exitCode: 0).get()
    }
    
    @Test func givenStatus_whenCalled_thenItPassesThroughToHarnessRepository() async throws {
        // given
        let harnessRepository = MockHarnessRepository()
        let expected: Result<SetupDocument, ToolError> = .success(try document(#"{"v":1,"server_path":"/bin/polybridge","clients":[]}"#))
        given(harnessRepository).status().willReturn(expected)
        let sut = HarnessesViewRepository(harnessRepository: harnessRepository)
        
        // when
        let result = await sut.status()
        
        // then
        guard case .success(let document) = result else {
            Issue.record("expected success")
            return
        }
        #expect(document.serverPath == "/bin/polybridge")
    }
    
    @Test func givenPerform_whenCalled_thenTheActionAndClientPassThrough() async throws {
        // given
        let harnessRepository = MockHarnessRepository()
        given(harnessRepository).perform(.any, client: .value("codex"), using: .any).willReturn(.success(try document(#"{"v":1,"clients":[]}"#)))
        let sut = HarnessesViewRepository(harnessRepository: harnessRepository)
        let located = SetupClient(executable: "/located/polybridge-setup", environment: [:])
        
        // when
        _ = await sut.perform(.install, client: "codex", using: located)
        
        // then — the action runs with the client `run` already located, not a second lookup
        verify(harnessRepository).perform(.any, client: .value("codex"), using: .matching { $0.executable == "/located/polybridge-setup" }).called(1)
    }
    
    // MARK: item 8 — locate() asks the tool-environment locator directly and returns the client
    
    @Test func givenLocateSucceeds_whenCalled_thenItReturnsTheLocatedClient() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).setup().willReturn(.success(SetupClient(executable: "/bin/polybridge-setup", environment: [:])))
        let sut = HarnessesViewRepository(toolEnvironmentRepository: toolEnvironment)
        
        // when
        let result = sut.locate()
        
        // then
        guard case .success(let client) = result else {
            Issue.record("expected success")
            return
        }
        #expect(client.executable == "/bin/polybridge-setup")
        verify(toolEnvironment).setup().called(1)
    }
    
    @Test func givenLocateFails_whenCalled_thenTheFailureForwardsThrough() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let failure = ToolError.notFound(tool: "polybridge-setup", searched: ["/usr/local/bin"])
        given(toolEnvironment).setup().willReturn(.failure(failure))
        let sut = HarnessesViewRepository(toolEnvironmentRepository: toolEnvironment)
        
        // when
        let result = sut.locate()
        
        // then
        guard case .failure(let error) = result else {
            Issue.record("expected failure")
            return
        }
        #expect(error == failure)
    }
}
