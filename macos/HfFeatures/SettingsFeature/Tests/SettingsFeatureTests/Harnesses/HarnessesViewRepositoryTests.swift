import Combine
import Foundation
import HfRepository
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct HarnessesViewRepositoryTests {
    
    private func document(_ json: String) throws -> SetupDocument {
        var object = JSONValue.parse(Data(json.utf8))!.objectValue!
        object["product"] = object["product"] ?? .string("harflow")
        object["format"] = object["format"] ?? .string("harflow.setup")
        object["product_version"] = object["product_version"] ?? .string("0.0.1")
        return try SetupDocument.decode(stdout: Data(JSONValue.object(object).rendered().utf8), stderr: "", exitCode: 0).get()
    }
    
    @Test func givenStatus_whenCalled_thenItPassesThroughToHarnessRepository() async throws {
        // given
        let harnessRepository = MockHarnessRepository()
        let expected: Result<SetupDocument, ToolError> = .success(try document(#"{"v":1,"server_path":"/bin/harflow","clients":[]}"#))
        given(harnessRepository).status().willReturn(expected)
        let sut = HarnessesViewRepository(harnessRepository: harnessRepository)
        
        // when
        let result = await sut.status()
        
        // then
        guard case .success(let document) = result else {
            Issue.record("expected success")
            return
        }
        #expect(document.serverPath == "/bin/harflow")
    }
    
    @Test func givenPerform_whenCalled_thenTheActionAndClientPassThrough() async throws {
        // given
        let harnessRepository = MockHarnessRepository()
        given(harnessRepository).perform(.any, client: .value("codex"), using: .any).willReturn(.success(try document(#"{"v":1,"clients":[]}"#)))
        let sut = HarnessesViewRepository(harnessRepository: harnessRepository)
        let located = SetupClient(executable: "/located/harflow-setup", environment: [:])
        
        // when
        _ = await sut.perform(.install, client: "codex", using: located)
        
        // then — the action runs with the client `run` already located, not a second lookup
        verify(harnessRepository).perform(.any, client: .value("codex"), using: .matching { $0.executable == "/located/harflow-setup" }).called(1)
    }
    
    // MARK: item 8 — locate() asks the tool-environment locator directly and returns the client
    
    @Test func givenLocateSucceeds_whenCalled_thenItReturnsTheLocatedClient() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).setup().willReturn(.success(SetupClient(executable: "/bin/harflow-setup", environment: [:])))
        let sut = HarnessesViewRepository(toolEnvironmentRepository: toolEnvironment)
        
        // when
        let result = sut.locate()
        
        // then
        guard case .success(let client) = result else {
            Issue.record("expected success")
            return
        }
        #expect(client.executable == "/bin/harflow-setup")
        verify(toolEnvironment).setup().called(1)
    }
    
    @Test func givenLocateFails_whenCalled_thenTheFailureForwardsThrough() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let failure = ToolError.notFound(tool: "harflow-setup", searched: ["/usr/local/bin"])
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

    @Test func givenSetupState_whenRead_thenItPassesThrough() {
        // given
        let install = MockInstallRepository()
        given(install).setupState.willReturn(.installing)
        let sut = HarnessesViewRepository(installRepository: install)

        // then
        #expect(sut.runtimeSetupState == .installing)
    }

    @Test func givenRuntimeSetupPublisher_whenRead_thenCurrentSnapshotAndChangesPassThrough() {
        // given
        let install = MockInstallRepository()
        let setup = CurrentValueSubject<RuntimeSetupState, Never>(.checking)
        given(install).setupStatePublisher().willReturn(setup.eraseToAnyPublisher())
        let sut = HarnessesViewRepository(installRepository: install)
        var received: [RuntimeSetupState] = []

        // when
        let token = sut.runtimeSetupPublisher().sink { received.append($0) }
        setup.send(.ready)

        // then
        #expect(received == [.checking, .ready])
        withExtendedLifetime(token) {}
    }
}
