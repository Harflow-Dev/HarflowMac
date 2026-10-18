import Foundation
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

/// R2-4: `discoverEnvironment()` publishes one coherent `DiscoveryResult`, is coalesced/awaitable,
/// and ignores timed-out probes rather than treating them as answers.
extension ToolEnvironmentRepositoryImplTests {

    // MARK: Interactive shell PATH

    @Test func givenAnInteractiveShellAddsDirectories_whenDiscovering_thenTheyFollowTheLoginPath() async {
        // given — the login shell lacks what ~/.zshrc adds (nvm's node bin, ~/.opencode/bin).
        let runner = StubProcessRunner { call in
            if call.arguments.contains("-i") { return .success(stdout("/usr/bin:/nvm/bin:/home/.opencode/bin\n")) }
            if call.executable == LaunchEnvironment.loginPathArgv[0] { return .success(stdout("/usr/bin:/home/.local/bin\n")) }
            return .success(stdout(""))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: "/home", baseEnvironment: [:], runner: runner, settings: settings, isExecutable: { _ in false })

        // when
        let result = await sut.discoverEnvironment()

        // then
        #expect(result.loginPath == "/usr/bin:/home/.local/bin:/nvm/bin:/home/.opencode/bin")
    }

    @Test func givenTheInteractiveProbeTimesOut_whenDiscovering_thenTheLoginPathStands() async {
        // given
        let runner = StubProcessRunner { call in
            if call.arguments.contains("-i") { return .success(ProcessOutput(exitCode: 0, stdout: Data("/nvm/bin".utf8), stderr: "", timedOut: true)) }
            if call.executable == LaunchEnvironment.loginPathArgv[0] { return .success(stdout("/usr/bin\n")) }
            return .success(stdout(""))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: "/home", baseEnvironment: [:], runner: runner, settings: settings, isExecutable: { _ in false })

        // when
        let result = await sut.discoverEnvironment()

        // then
        #expect(result.loginPath == "/usr/bin")
    }

    @Test func givenPaths_whenMerging_thenOrderIsKeptAndDuplicatesAndEmptiesDrop() {
        // given / when / then
        #expect(ToolEnvironmentRepositoryImpl.mergedPath("/a:/b", "/b:/c::/a") == "/a:/b:/c")
        #expect(ToolEnvironmentRepositoryImpl.mergedPath(nil, "/c") == "/c")
        #expect(ToolEnvironmentRepositoryImpl.mergedPath("/a", nil) == "/a")
        #expect(ToolEnvironmentRepositoryImpl.mergedPath(nil, nil) == nil)
    }

    // MARK: PATH candidate order and dedup

    @Test func givenBothAFixedCandidateAndADifferentLoginPathCandidateAreExecutable_whenDiscovering_thenTheFixedCandidateWinsFirst() async {
        // given — `ToolLocator.uvCandidates(home:)` is searched before anything found by walking the
        // login PATH.
        let home = "/Users/fixture-\(UUID().uuidString)"
        let fixedUv = home + "/.local/bin/uv"
        let loginOnlyUv = "/some/other/dir/uv"
        let runner = StubProcessRunner { call in
            if call.executable == LaunchEnvironment.loginPathArgv[0] { return .success(stdout("/some/other/dir\n")) }
            if call.executable == fixedUv { return .success(stdout("/fixed/bin\n")) }
            return .success(stdout("/login/bin\n"))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(
            home: home, baseEnvironment: [:], runner: runner, settings: settings,
            isExecutable: { $0 == fixedUv || $0 == loginOnlyUv }
        )

        // when
        let result = await sut.discoverEnvironment()

        // then
        #expect(result.uv?.executable == fixedUv)
        #expect(result.uv?.binDirectory == "/fixed/bin")
    }

    @Test func givenNoFixedCandidateIsExecutable_whenALoginPathCandidateIs_thenItIsUsed() async {
        // given
        let home = "/Users/fixture-\(UUID().uuidString)"
        let loginOnlyUv = "/some/other/dir/uv"
        let runner = StubProcessRunner { call in
            if call.executable == LaunchEnvironment.loginPathArgv[0] { return .success(stdout("/some/other/dir\n")) }
            return .success(stdout("/login/bin\n"))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(
            home: home, baseEnvironment: [:], runner: runner, settings: settings,
            isExecutable: { $0 == loginOnlyUv }
        )

        // when
        let result = await sut.discoverEnvironment()

        // then
        #expect(result.uv?.executable == loginOnlyUv)
        #expect(result.uv?.binDirectory == "/login/bin")
    }

    @Test func givenTheLoginPathRepeatsAFixedCandidatesDirectory_whenDiscovering_thenItIsProbedOnlyOnce() async {
        // given — the probe fails, so discovery keeps walking candidates: if dedup failed, the same
        // uv (named both by `ToolLocator.uvCandidates` and twice over in the login PATH, once with a
        // trailing slash) would be probed three times instead of once.
        let home = "/Users/fixture-\(UUID().uuidString)"
        let uvPath = home + "/.local/bin/uv"
        let probeCalls = LockedBox(0)
        let runner = StubProcessRunner { call in
            if call.executable == LaunchEnvironment.loginPathArgv[0] {
                return .success(stdout(home + "/.local/bin:" + home + "/.local/bin/\n"))
            }
            probeCalls.mutate { $0 += 1 }
            return .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: "", timedOut: false))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(
            home: home, baseEnvironment: [:], runner: runner, settings: settings,
            isExecutable: { $0 == uvPath }
        )

        // when
        let result = await sut.discoverEnvironment()

        // then
        #expect(result.uv == nil)
        #expect(probeCalls.value == 1)
    }

    // MARK: Timed-out probes are ignored

    @Test func givenTheLoginPathProbeTimesOut_whenDiscovering_thenLoginPathStaysNilDespiteExitZero() async {
        // given
        let home = "/Users/fixture-\(UUID().uuidString)"
        let runner = StubProcessRunner { call in
            if call.executable == LaunchEnvironment.loginPathArgv[0] {
                return .success(ProcessOutput(exitCode: 0, stdout: Data("/usr/bin\n".utf8), stderr: "", timedOut: true))
            }
            return .success(stdout(""))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: home, baseEnvironment: [:], runner: runner, settings: settings, isExecutable: { _ in false })

        // when
        let result = await sut.discoverEnvironment()

        // then
        #expect(result.loginPath == nil)
    }

    @Test func givenAUvCandidateProbeTimesOut_whenDiscovering_thenItIsTreatedAsNotFoundRatherThanAMatch() async {
        // given — exit 0 alone must not be enough once `timedOut` is set.
        let home = "/Users/fixture-\(UUID().uuidString)"
        let uvPath = home + "/.local/bin/uv"
        let runner = StubProcessRunner { call in
            if call.executable == LaunchEnvironment.loginPathArgv[0] { return .success(stdout("/usr/bin\n")) }
            return .success(ProcessOutput(exitCode: 0, stdout: Data("/tool/bin\n".utf8), stderr: "", timedOut: true))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: home, baseEnvironment: [:], runner: runner, settings: settings, isExecutable: { $0 == uvPath })

        // when
        let result = await sut.discoverEnvironment()

        // then
        #expect(result.uv == nil)
    }

    // MARK: A stale resolution is cleared

    @Test func givenAPreviousDiscoveryFoundUv_whenALaterDiscoveryFindsNone_thenTheStaleResolutionIsCleared() async {
        // given
        let home = "/Users/fixture-\(UUID().uuidString)"
        let shouldFindUv = LockedBox(true)
        let runner = StubProcessRunner { call in
            if call.executable == LaunchEnvironment.loginPathArgv[0] { return .success(stdout("/usr/bin\n")) }
            return .success(stdout("/tool/bin\n"))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: home, baseEnvironment: [:], runner: runner, settings: settings, isExecutable: { _ in shouldFindUv.value })
        _ = await sut.discoverEnvironment()
        #expect(sut.discovery.uv != nil)

        // when — uv "disappears" (e.g. the folder was removed) before the next discovery.
        shouldFindUv.mutate { $0 = false }
        _ = await sut.discoverEnvironment()

        // then — not left over from the previous run.
        #expect(sut.discovery.uv == nil)
    }

    // MARK: Coalesced, awaitable discovery

    @Test func givenACallArrivesWhileAPassIsRunning_whenBothSettle_thenTheLaterCallerGetsALaterPassResult() async {
        // given — a runner that blocks the very first login-PATH probe until released, so a second
        // `discoverEnvironment()` call is guaranteed to arrive while the first pass is still running.
        let home = "/Users/fixture-\(UUID().uuidString)"
        let uvPath = home + "/.local/bin/uv"
        let gate = AsyncGate()
        let passCount = LockedBox(0)
        let runner = StubProcessRunner { call in
            // The interactive-shell PATH probe runs in every pass too; only the login probe counts one.
            if call.arguments.contains("-i") { return .success(stdout("/usr/bin\n")) }
            if call.executable == LaunchEnvironment.loginPathArgv[0] {
                let thisPass = passCount.value + 1
                passCount.mutate { $0 = thisPass }
                if thisPass == 1 { gate.waitSync() }
                return .success(stdout("/usr/bin\n"))
            }
            return .success(stdout("/tool/bin-pass\(passCount.value)\n"))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: home, baseEnvironment: [:], runner: runner, settings: settings, isExecutable: { $0 == uvPath })

        // when
        let firstCall = Task { await sut.discoverEnvironment() }
        await waitUntil { passCount.value >= 1 }
        let secondCall = Task { await sut.discoverEnvironment() }
        try? await Task.sleep(for: .milliseconds(50)) // let the second call register as a waiter
        gate.open()
        let firstResult = await firstCall.value
        let secondResult = await secondCall.value

        // then — the first caller (which claimed and ran pass 1 itself) gets pass 1's own result;
        // the second caller (which arrived mid-pass-1 and had to be armed a fresh pass) gets pass
        // 2's result — never pass 1's, which had already started before its call.
        #expect(firstResult.uv?.binDirectory == "/tool/bin-pass1")
        #expect(secondResult.uv?.binDirectory == "/tool/bin-pass2")
    }

    // MARK: A newer result is never clobbered by a slower, earlier-starting one

    @Test func givenStartupDiscoveryFinishesAfterAnInstallTriggeredOneWasArmed_whenBothSettle_thenThePublishedResultIsTheNewerOne() async {
        // given — same mechanics as the coalescing test above: since only one pass ever runs at a
        // time, whichever pass is *last* to publish is always the one that started later, so the
        // synchronous `discovery` snapshot must reflect it — simulating "startup discovery" as the
        // slow first pass and "install-triggered" discovery as the second.
        let home = "/Users/fixture-\(UUID().uuidString)"
        let uvPath = home + "/.local/bin/uv"
        let gate = AsyncGate()
        let passCount = LockedBox(0)
        let runner = StubProcessRunner { call in
            // The interactive-shell PATH probe runs in every pass too; only the login probe counts one.
            if call.arguments.contains("-i") { return .success(stdout("/usr/bin\n")) }
            if call.executable == LaunchEnvironment.loginPathArgv[0] {
                let thisPass = passCount.value + 1
                passCount.mutate { $0 = thisPass }
                if thisPass == 1 { gate.waitSync() }
                return .success(stdout("/usr/bin\n"))
            }
            return .success(stdout("/tool/bin-pass\(passCount.value)\n"))
        }
        let settings = SettingsRepositoryImpl(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let sut = ToolEnvironmentRepositoryImpl(home: home, baseEnvironment: [:], runner: runner, settings: settings, isExecutable: { $0 == uvPath })

        // when — "startup discovery" starts first and is slow; "install-triggered" discovery arrives
        // while it's still in flight.
        let startupDiscovery = Task { await sut.discoverEnvironment() }
        await waitUntil { passCount.value >= 1 }
        let installTriggeredDiscovery = Task { await sut.discoverEnvironment() }
        try? await Task.sleep(for: .milliseconds(50))
        gate.open()
        _ = await startupDiscovery.value
        _ = await installTriggeredDiscovery.value

        // then
        #expect(sut.discovery.uv?.binDirectory == "/tool/bin-pass2")
    }
}
