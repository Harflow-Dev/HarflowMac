import Foundation
@testable import MonitorCore
import Testing

extension CtlDecodingTests {
    @Test
    func givenUnsupportedSetupOutput_whenDecoded_thenItIsRefused() {
        let unsupported = #"{"product":"harflow","format":"harflow.setup","v":2,"product_version":"0.0.1", "# + #""clients":[]}"#
        guard case .failure(.unsupportedVersion) = SetupDocument.decode(stdout: json(unsupported), stderr: "", exitCode: 0) else {
            Issue.record("expected .unsupportedVersion")
            return
        }
        guard case .failure(.unsupportedCommand) = SetupDocument.decode(stdout: Data(), stderr: "error: unrecognized arguments: --json", exitCode: 2) else {
            Issue.record("expected .unsupportedCommand")
            return
        }
    }
}

extension SetupTests {
    @Test
    func givenAFakeSetupBinary_whenInstallingAndRemoving_thenOnlyTheFakeBinaryRuns() async throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls.log").path
        let versionInfo = "{" +
            "\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
            "\"product_version\":\"\(HarflowVersion.current)\",\"component\":\"engine\",\"state_root\":\"\(dir.path)/.harflow\"," +
            "\"contracts\":{\"setup\":{\"format\":\"harflow.setup\",\"v\":1}}," +
            "\"capabilities\":[\"setup.v1\"],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
        let ctl = try writeFakeTool(dir, name: "harflow-ctl", body: """
        printf '%s\\n' '\(versionInfo)'
        """)
        // A fake harflow-setup: logs its argv and answers a v1 document naming the action.
        let removedDocument =
            #"{"product":"harflow","format":"harflow.setup","v":1,"product_version":"\#(HarflowVersion.current)","server_path":null,"clients":["#
            + #"{"key":"codex","available":true,"installed":true,"command":null,"current":null,"action":"removed","error":null,"notes":[] }]}"#
        let applied = removedDocument.replacingOccurrences(of: "removed", with: "applied")
        let setup = try writeFakeTool(dir, name: "harflow-setup", body: """
        echo "$@" >> '\(log)'
        case "$1" in --uninstall) act=removed ;; --status) act=null ;; *) act=applied ;; esac
        if [ "$act" = "removed" ]; then
          echo '\(removedDocument)'
        else
          echo '\(applied)'
        fi
        """)
        let client = SetupClient(executable: setup, environment: ["HOME": dir.path], pairedCtlExecutable: ctl)
        // when
        let removed = try await client.perform(.remove, client: "codex").get()
        let installed = try await client.perform(.install, client: "codex").get()
        // then
        #expect(removed.rows.first?.action == "removed")
        #expect(installed.rows.first?.action == "applied")
        let calls = try String(contentsOfFile: log, encoding: .utf8)
        #expect(calls == "--uninstall --client=codex --json\n--client=codex --json\n")
    }
}
