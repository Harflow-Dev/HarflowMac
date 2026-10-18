import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import Testing

private func harnessSetup(_ payload: String) -> ProcessOutput {
    guard var object = JSONValue.parse(Data(payload.utf8))?.objectValue else { return stdout(payload) }
    object["product"] = .string("harflow")
    object["format"] = .string("harflow.setup")
    object["v"] = .number(1)
    object["product_version"] = .string("1.0.0")
    return stdout(JSONValue.object(object).rendered())
}

@Suite struct HarnessRepositoryImplTests {

    @Test func givenSetupCannotBeLocated_whenAskingForStatus_thenTheLocatorFailureIsReturned() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).setup().willReturn(.failure(.notFound(tool: "harflow-setup", searched: ["/usr/local/bin"])))
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
        let runner = StubProcessRunner(compatibleOutput: harnessSetup(#"{"server_path":"/bin/harflow","clients":[{"key":"codex","available":true}]}"#))
        given(toolEnvironment).setup().willReturn(.success(SetupClient(executable: "/bin/harflow-setup", environment: [:], runner: runner)))
        let sut = HarnessRepositoryImpl(toolEnvironment: toolEnvironment)

        // when
        let result = await sut.perform(.install, client: "codex")

        // then
        guard case .success(let document) = result else {
            Issue.record("expected success")
            return
        }
        #expect(document.rows.first?.key == "codex")
        let installCall = runner.calls.first { call in
            call.arguments.contains("--client=codex")
        }
        #expect(installCall != nil)
    }
}
