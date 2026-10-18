@testable import HfRepository
import MonitorCore
import Testing

@Suite struct MCPAllowlistClientTests {
    @Test func givenApproval_whenRequested_thenArgumentsStaySeparateAndResultDecodes() async throws {
        // given
        let runner = StubProcessRunner(compatibleOutput: stdout(
            #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"1.0.0","result":{"supported":true,"entries":["harflow/*"]}}"#
        ))
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = try await client.mcpAllowlist(backend: "codex", allow: "harflow/*").get()
        // then
        #expect(result["supported"]?.boolValue == true)
        #expect(runner.calls.map(\.arguments) == [
            ["version-info", "--json"],
            ["mcp-allowlist", "--backend=codex", "--allow=harflow/*", "--json"]
        ])
        #expect(runner.calls.last?.arguments == ["mcp-allowlist", "--backend=codex", "--allow=harflow/*", "--json"])
    }

    @Test func givenFailedCompatibilityProbe_whenReadingAllowingAndRemoving_thenNoOperationLaunches() async {
        let runner = StubProcessRunner(output: stdout(#"{"product":"other","format":"other","v":1}"#))
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        _ = await client.mcpAllowlist(backend: "codex")
        _ = await client.mcpAllowlist(backend: "codex", allow: "harflow/*")
        _ = await client.mcpAllowlist(backend: "codex", remove: "harflow/*")
        #expect(runner.calls.count == 3)
        #expect(runner.calls.allSatisfy { $0.arguments == ["version-info", "--json"] })
    }

    @Test func givenCLIError_whenReading_thenErrorRemainsFailure() async {
        // given
        let runner = StubProcessRunner(compatibleOutput: stdout(
            #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"1.0.0","error":{"code":"invalid_config","message":"Invalid configuration"}}"#
        ))
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = await client.mcpAllowlist(backend: "codex")
        // then
        if case .failure(.refused(let code, let message)) = result {
            #expect(code == "invalid_config")
            #expect(message == "Invalid configuration")
        } else {
            Issue.record("CLI failure must remain a refused command result")
        }
        #expect(runner.calls.count == 2)
        #expect(runner.calls.last?.arguments == ["mcp-allowlist", "--backend=codex", "--json"])
    }
}
