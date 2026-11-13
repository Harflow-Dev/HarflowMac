import Foundation
@testable import MonitorCore
import Testing

// MARK: - HarnessPathDiscoveryTests

@Suite
struct HarnessPathDiscoveryTests {

    /// Answers the login and interactive probes with fixed output.
    private struct ProbeRunner: ProcessRunning {
        var login: ProcessOutput
        var interactive: ProcessOutput

        func run(executable _: String, arguments: [String], environment _: [String: String], currentDirectory _: String?,
                 timeout _: Double) async -> Result<ProcessOutput, ToolError> {
            .success(arguments.contains("-i") ? interactive : login)
        }
    }

    private func output(_ text: String, timedOut: Bool = false) -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdout: Data(text.utf8), stderr: "", timedOut: timedOut)
    }

    @Test
    func givenAnInteractiveShellAddsDirectories_whenDiscovering_thenTheyFollowTheLoginPath() async {
        // given
        let runner = ProbeRunner(login: output("/usr/bin:/home/.local/bin\n"), interactive: output("/usr/bin:/nvm/bin:/home/.opencode/bin\n"))

        // when
        let path = await LaunchEnvironment.discoverHarnessPath(home: "/home", environment: [:], runner: runner)

        // then
        #expect(path == "/usr/bin:/home/.local/bin:/nvm/bin:/home/.opencode/bin")
    }

    @Test
    func givenTheInteractiveProbeTimesOut_whenDiscovering_thenTheLoginPathStands() async {
        // given
        let runner = ProbeRunner(login: output("/usr/bin\n"), interactive: output("/nvm/bin", timedOut: true))

        // when
        let path = await LaunchEnvironment.discoverHarnessPath(home: "/home", environment: [:], runner: runner)

        // then
        #expect(path == "/usr/bin")
    }

    @Test
    func givenTheLoginProbeTimesOutWithExitZero_whenDiscovering_thenThePathIsNil() async {
        // given
        let runner = ProbeRunner(login: output("/usr/bin\n", timedOut: true), interactive: output(""))

        // when
        let path = await LaunchEnvironment.discoverHarnessPath(home: "/home", environment: [:], runner: runner)

        // then
        #expect(path == nil)
    }

    @Test
    func givenPaths_whenMerging_thenOrderIsKeptAndDuplicatesAndEmptiesDrop() {
        // given / when / then
        #expect(LaunchEnvironment.mergedPath("/a:/b", "/b:/c::/a") == "/a:/b:/c")
        #expect(LaunchEnvironment.mergedPath(nil, "/c") == "/c")
        #expect(LaunchEnvironment.mergedPath("/a", nil) == "/a")
        #expect(LaunchEnvironment.mergedPath(nil, nil) == nil)
    }
}
