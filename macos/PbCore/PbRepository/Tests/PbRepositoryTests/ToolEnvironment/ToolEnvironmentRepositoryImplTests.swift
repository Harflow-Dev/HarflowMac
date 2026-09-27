import Foundation
import MonitorCore
@testable import PbRepository
import Testing

@Suite struct ToolEnvironmentRepositoryImplTests {

    @Test func givenNoLoginPathYet_whenProbing_thenTheProbeRunsWithHomeAsCwdAndAnEightSecondTimeout() async {
        // given — F4-02
        let runner = StubProcessRunner(output: stdout("/usr/bin:/bin\n"))
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: "/Users/fixture", baseEnvironment: [:], runner: runner, settings: settings)

        // when
        _ = await sut.discoverEnvironment()

        // then
        let loginProbe = runner.calls.first { $0.executable == LaunchEnvironment.loginPathArgv[0] }
        #expect(loginProbe != nil)
        #expect(sut.environment()["PATH"]?.contains("/usr/bin") == true)
    }

    @Test func givenSeveralUvCandidates_whenProbed_thenTheFirstSuccessfulOneWins() async {
        // given — F4-03: only the second candidate is executable and answers 0.
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: home + "/.cargo/bin", withIntermediateDirectories: true)
        let uvPath = home + "/.cargo/bin/uv"
        FileManager.default.createFile(atPath: uvPath, contents: nil, attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(atPath: home) }

        let runner = StubProcessRunner { call in
            if call.arguments.first == "tool" { return .success(stdout("/tool/bin\n")) }
            return .success(stdout(""))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: home, baseEnvironment: [:], runner: runner, settings: settings)

        // when
        _ = await sut.discoverEnvironment()

        // then
        #expect(sut.locator.uvToolBin == "/tool/bin")
    }

    @Test func givenALocatedBinary_whenBuildingItsClient_thenItsOwnFolderIsOnThePath() {
        // given — F4-04
        let home = "/Users/fixture"
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.setToolDirectory(home + "/toolbin")
        let sut = ToolEnvironmentRepositoryImpl(
            home: home, baseEnvironment: [:], runner: StubProcessRunner(output: stdout("")), settings: settings
        )

        // when
        let env = sut.environment(toolDirectory: home + "/toolbin")

        // then
        #expect(env["PATH"]?.hasPrefix(home + "/toolbin") == true)
    }

    @Test func givenToolDirectorySettingChanges_whenLocatorIsRead_thenOnlyTheOverrideIsReReadNotTheProbes() async {
        // given — decision 11 / F4-05: changing the Settings override re-reads live; the login-PATH
        // and uv probes never rerun.
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let runner = StubProcessRunner(output: stdout("/usr/bin\n"))
        let sut = ToolEnvironmentRepositoryImpl(home: "/Users/fixture", baseEnvironment: [:], runner: runner, settings: settings)
        _ = await sut.discoverEnvironment()
        let callsAfterDiscovery = runner.calls.count

        // when
        settings.setToolDirectory("/opt/homebrew/bin")

        // then
        #expect(sut.locator.overrideDirectory == "/opt/homebrew/bin")
        #expect(runner.calls.count == callsAfterDiscovery)
    }

    @Test func givenCtlCannotBeLocated_whenAskedForACtlClient_thenItFailsWithNotFound() {
        // given
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(
            home: "/nonexistent-\(UUID().uuidString)", baseEnvironment: [:],
            runner: StubProcessRunner(output: stdout("")), settings: settings
        )

        // when
        let result = sut.ctl()

        // then
        guard case .failure(let error) = result, case .notFound = error else {
            Issue.record("expected .notFound")
            return
        }
    }
}
