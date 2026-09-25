import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import Testing

@Suite struct HarnessRepositoryImplTests {

    @Test func givenSetupCannotBeLocated_whenAskingForStatus_thenTheLocatorFailureIsReturned() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).setup().willReturn(.failure(.notFound(tool: "polybridge-setup", searched: ["/usr/local/bin"])))
        let sut = HarnessRepositoryImpl(toolEnvironment: toolEnvironment)

        // when
        let result = await sut.status()

        // then
        guard case .failure(let error) = result, case .notFound = error else {
            Issue.record("expected .notFound")
            return
        }
    }

    @Test func givenSetupIsLocated_whenPerformingInstall_thenTheClientPerformsInstallWithTheGivenKey() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":1,"server_path":"/bin/polybridge","clients":[{"key":"codex","available":true}]}"#))
        given(toolEnvironment).setup().willReturn(.success(SetupClient(executable: "/bin/polybridge-setup", environment: [:], runner: runner)))
        let sut = HarnessRepositoryImpl(toolEnvironment: toolEnvironment)

        // when
        let result = await sut.perform(.install, client: "codex")

        // then
        guard case .success(let document) = result else {
            Issue.record("expected success")
            return
        }
        #expect(document.rows.first?.key == "codex")
        #expect(runner.calls.first?.arguments.contains("--client=codex") == true)
    }
}
