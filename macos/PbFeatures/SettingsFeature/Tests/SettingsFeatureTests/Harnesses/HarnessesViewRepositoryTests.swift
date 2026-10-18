import Combine
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

    // MARK: - Install (settled plan, section 5)

    @Test func givenInstallRepositoryValues_whenReadOrActed_thenTheyPassThrough() async {
        // given
        let install = MockInstallRepository()
        given(install).state.willReturn(.needsUv)
        given(install).lastCheckMessage.willReturn("checking")
        given(install).installAnywayBlockedMessage.willReturn("blocked")
        given(install).destination().willReturn("/Users/x/.local/bin")
        given(install).statePublisher().willReturn(Just(InstallState.needsUv).eraseToAnyPublisher())
        given(install).lastCheckMessagePublisher().willReturn(Just("checking").eraseToAnyPublisher())
        given(install).installAnywayBlockedMessagePublisher().willReturn(Just("blocked").eraseToAnyPublisher())
        given(install).install().willReturn()
        given(install).installUvThenPolybridge().willReturn()
        given(install).retry().willReturn()
        given(install).checkAgain().willReturn()
        given(install).installAnyway().willReturn(true)
        given(install).reset().willReturn()
        let sut = HarnessesViewRepository(installRepository: install)

        // then — reads
        #expect(sut.installState == .needsUv)
        #expect(sut.lastCheckMessage == "checking")
        #expect(sut.installAnywayBlockedMessage == "blocked")
        #expect(sut.installDestination() == "/Users/x/.local/bin")

        // when — actions
        await sut.install()
        await sut.installUvThenPolybridge()
        await sut.retry()
        await sut.checkAgain()
        let allowed = await sut.installAnyway()
        sut.reset()

        // then
        #expect(allowed)
        verify(install).install().called(1)
        verify(install).installUvThenPolybridge().called(1)
        verify(install).retry().called(1)
        verify(install).checkAgain().called(1)
        verify(install).installAnyway().called(1)
        verify(install).reset().called(1)
    }

    @Test func givenBothToolsMissing_whenInstallNeedIsComputed_thenTheClassifierSaysMissing() {
        // given — `installNeed(for:)` locates both tools fresh through `ToolEnvironmentRepository`
        // rather than trusting the error's own claim, then hands the classifier both presences.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).locator.willReturn(
            ToolLocator(overrideDirectory: nil, home: "/Users/x", uvToolBin: nil, isExecutable: { _ in false })
        )
        let sut = HarnessesViewRepository(toolEnvironmentRepository: toolEnvironment)

        // when
        let need = sut.installNeed(for: .notFound(tool: "polybridge-ctl", searched: []))

        // then
        #expect(need == .missing)
    }
}
