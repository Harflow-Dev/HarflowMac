import MonitorCore
@testable import PbRepository
import Testing

@Suite struct MCPAllowlistClientTests {
    @Test func givenApproval_whenRequested_thenArgumentsStaySeparateAndResultDecodes() async throws {
        // given
        let runner = StubProcessRunner(output: stdout(#"{"v":1,"result":{"supported":true,"entries":["polybridge/*"]}}"#))
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = try await client.mcpAllowlist(backend: "codex", allow: "polybridge/*").get()
        // then
        #expect(result["supported"]?.boolValue == true)
        #expect(runner.calls.first?.arguments == ["mcp-allowlist", "--backend=codex", "--allow=polybridge/*", "--json"])
    }

    @Test func givenCLIError_whenReading_thenErrorRemainsFailure() async {
        // given
        let runner = StubProcessRunner(output: stdout(#"{"v":1,"error":{"code":"invalid_config","message":"Invalid configuration"}}"#))
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = await client.mcpAllowlist(backend: "codex")
        // then
        if case .success = result { Issue.record("CLI failure must not become an empty approval list") }
    }
}
