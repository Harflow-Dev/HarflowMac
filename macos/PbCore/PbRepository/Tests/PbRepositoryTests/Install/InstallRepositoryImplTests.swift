import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct InstallRepositoryImplTests {

    // MARK: Fixtures

    static let home = "/Users/fixture"
    static let destination = "/Users/fixture/uv-bin"
    static let uvExecutable = "/usr/local/bin/uv"
    static let gitPath = "/opt/homebrew/bin/git"
    static let pathEnvironment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]

    static var ctlPath: String { destination + "/polybridge-ctl" }
    static var setupPath: String { destination + "/polybridge-setup" }

    static func uv(binDirectory: String = destination) -> UvResolution { UvResolution(executable: uvExecutable, binDirectory: binDirectory) }

    static func makeLocator(
        overrideDirectory: String? = nil,
        uvToolBin: String? = destination,
        isExecutable: @escaping @Sendable (String) -> Bool = { $0 == InstallRepositoryImplTests.ctlPath || $0 == InstallRepositoryImplTests.setupPath }
    ) -> ToolLocator {
        ToolLocator(overrideDirectory: overrideDirectory, home: home, uvToolBin: uvToolBin, isExecutable: isExecutable)
    }

    /// A `MockToolEnvironmentRepository` already known to have `uv` (so `install()` goes straight to
    /// the polybridge stage) and whose `locator` resolves both binaries to `destination` (so
    /// validation's "effective selection" step finds no shadow) — the happy-path default every test
    /// starts from and overrides only what it needs to.
    static func makeToolEnvironment(
        uv: UvResolution? = InstallRepositoryImplTests.uv(),
        overrideDirectory: String? = nil,
        locatorIsExecutable: @escaping @Sendable (String) -> Bool = { $0 == InstallRepositoryImplTests.ctlPath || $0 == InstallRepositoryImplTests.setupPath }
    ) -> MockToolEnvironmentRepository {
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).home.willReturn(home)
        given(toolEnvironment).environment(toolDirectory: .any).willReturn(pathEnvironment)
        let discovery = DiscoveryResult(loginPath: pathEnvironment["PATH"], uv: uv)
        given(toolEnvironment).discoverEnvironment().willReturn(discovery)
        given(toolEnvironment).discovery.willReturn(discovery)
        given(toolEnvironment).locator.willReturn(
            ToolLocator(overrideDirectory: overrideDirectory, home: home, uvToolBin: uv?.binDirectory, isExecutable: locatorIsExecutable)
        )
        return toolEnvironment
    }

    static func makeSettings(toolDirectory: String = "") -> MockSettingsRepository {
        let settings = MockSettingsRepository()
        given(settings).toolDirectory.willReturn(toolDirectory)
        return settings
    }

    static func makeTaskList(refreshAndWait: Result<Void, ToolError> = .success(())) -> MockTaskListRepository {
        let taskList = MockTaskListRepository()
        given(taskList).refreshAndWait().willReturn(refreshAndWait)
        return taskList
    }

    /// The happy-path runner: git check, uv bootstrap, polybridge install, the running-installer
    /// probe (clean), and both validation contracts all succeed. Individual tests override the one
    /// call they care about via `override`.
    static func makeRunner(
        pgrepExitCode: Int32 = 1,
        ctlListJSON: String = #"{"v":2,"tasks":[]}"#,
        setupStatusJSON: String = #"{"v":1,"clients":[]}"#,
        override: (@Sendable (StubProcessRunner.Call) -> Result<ProcessOutput, ToolError>?)? = nil
    ) -> StubProcessRunner {
        StubProcessRunner { call in
            if let overridden = override?(call) { return overridden }
            switch call.executable {
            case gitPath: return .success(stdout("git version 2.42.0"))
            case InstallCommands.xcodeSelectExecutable: return .success(stdout(""))
            case InstallCommands.curlExecutable: return .success(stdout(""))
            case InstallCommands.shExecutable: return .success(stdout(""))
            case uvExecutable: return .success(stdout(""))
            case InstallCommands.pgrepExecutable:
                return .success(ProcessOutput(exitCode: pgrepExitCode, stdout: Data(), stderr: "", timedOut: false))
            case ctlPath: return .success(stdout(ctlListJSON))
            case setupPath: return .success(stdout(setupStatusJSON))
            default: return .success(stdout(""))
            }
        }
    }

    func makeSUT(
        toolEnvironment: MockToolEnvironmentRepository = InstallRepositoryImplTests.makeToolEnvironment(),
        taskList: MockTaskListRepository = InstallRepositoryImplTests.makeTaskList(),
        settings: MockSettingsRepository = InstallRepositoryImplTests.makeSettings(),
        runner: ProcessRunning = InstallRepositoryImplTests.makeRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { path in
            path == InstallRepositoryImplTests.gitPath || path == InstallRepositoryImplTests.ctlPath || path == InstallRepositoryImplTests.setupPath
        }
    ) -> InstallRepositoryImpl {
        InstallRepositoryImpl(
            toolEnvironment: toolEnvironment, taskListRepository: taskList, settings: settings,
            runner: runner, isExecutable: isExecutable, fileSize: { _ in 100 },
            makeTemporaryFile: { FileManager.default.temporaryDirectory.appendingPathComponent("fixture-uv-install-\(UUID().uuidString).sh").path }
        )
    }

    // MARK: needsGit / needsUv

    @Test func givenGitCannotBeFound_whenInstalling_thenStateBecomesNeedsGit() async {
        // given
        let sut = makeSUT(isExecutable: { _ in false })

        // when
        await sut.install()

        // then
        #expect(sut.state == .needsGit)
    }

    @Test func givenUvIsNotYetKnown_whenInstalling_thenStateBecomesNeedsUv() async {
        // given
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(uv: nil)
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.install()

        // then
        #expect(sut.state == .needsUv)
    }

    @Test func givenUvAlreadyKnown_whenInstalling_thenItGoesStraightToPolybridgeAndSucceeds() async {
        // given
        let sut = makeSUT()

        // when
        await sut.install()

        // then
        #expect(sut.state == .installed)
    }

    // MARK: uv bootstrap failures

    @Test func givenTheUvDownloadFails_whenInstallingUv_thenItFailsAtTheUvStage() async {
        // given
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(uv: nil)
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallCommands.curlExecutable
                ? .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: "curl: could not resolve host", timedOut: false))
                : nil
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment, runner: runner)
        await sut.install()
        #expect(sut.state == .needsUv)

        // when
        await sut.installUvThenPolybridge()

        // then
        guard case .failed(let stage, let message) = sut.state, stage == .uv else {
            Issue.record("expected failed(.uv, _), got \(sut.state)")
            return
        }
        #expect(message.contains("Downloading"))
    }

    @Test func givenTheUvInstallerScriptFails_whenInstallingUv_thenItFailsAtTheUvStage() async {
        // given
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(uv: nil)
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallCommands.shExecutable
                ? .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: "permission denied", timedOut: false))
                : nil
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment, runner: runner)
        await sut.install()

        // when
        await sut.installUvThenPolybridge()

        // then
        guard case .failed(let stage, let message) = sut.state, stage == .uv else {
            Issue.record("expected failed(.uv, _), got \(sut.state)")
            return
        }
        #expect(message.contains("Installing uv"))
    }

    @Test func givenUvBootstrapSucceedsButUvStillIsntFound_whenInstallingUv_thenItFailsAtTheUvStage() async {
        // given — download and run both exit 0, but the follow-up discovery still finds no `uv`.
        let toolEnvironment = InstallRepositoryImplTests.makeToolEnvironment(uv: nil)
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        await sut.install()

        // when
        await sut.installUvThenPolybridge()

        // then
        guard case .failed(let stage, let message) = sut.state, stage == .uv else {
            Issue.record("expected failed(.uv, _), got \(sut.state)")
            return
        }
        #expect(message.contains("still couldn't be found"))
    }

    @Test func givenUvBootstrapSucceedsAndUvIsThenFound_whenInstallingUv_thenItContinuesToPolybridgeAndValidates() async {
        // given — `install()` first sees no `uv` (needsUv); the follow-up `discoverEnvironment()`
        // inside the bootstrap now reports it found, so the continuation should run all the way to
        // `installed` inside the same guarded operation (F.4 "uv-then-polybridge continuation").
        // Discovery reports (and publishes) uv only once the installer script has run.
        let discoveredUv = LockedBox<UvResolution?>(nil)
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).home.willReturn(InstallRepositoryImplTests.home)
        given(toolEnvironment).environment(toolDirectory: .any).willReturn(InstallRepositoryImplTests.pathEnvironment)
        given(toolEnvironment).discovery.willProduce { DiscoveryResult(loginPath: nil, uv: discoveredUv.value) }
        given(toolEnvironment).discoverEnvironment().willProduce { DiscoveryResult(loginPath: nil, uv: discoveredUv.value) }
        given(toolEnvironment).locator.willReturn(InstallRepositoryImplTests.makeLocator())
        let runner = InstallRepositoryImplTests.makeRunner { call in
            if call.executable == InstallCommands.shExecutable { discoveredUv.mutate { $0 = InstallRepositoryImplTests.uv() } }
            return nil
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment, runner: runner)
        await sut.install()
        #expect(sut.state == .needsUv)

        // when
        await sut.installUvThenPolybridge()

        // then
        #expect(sut.state == .installed)
    }

    // MARK: polybridge stage failures

    @Test func givenPolybridgeInstallLaunchFails_whenInstalling_thenItFailsAtThePolybridgeStage() async {
        // given
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallRepositoryImplTests.uvExecutable
                ? .failure(.launchFailed(tool: "uv", detail: "no such file"))
                : nil
        }
        let sut = makeSUT(runner: runner)

        // when
        await sut.install()

        // then
        guard case .failed(let stage, _) = sut.state, stage == .polybridge else {
            Issue.record("expected failed(.polybridge, _), got \(sut.state)")
            return
        }
    }

    @Test func givenPolybridgeInstallExitsNonZero_whenInstalling_thenTheMessageIncludesTheStderrTail() async {
        // given
        let stderrLines = (1 ... 8).map { "line \($0)" }.joined(separator: "\n")
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallRepositoryImplTests.uvExecutable
                ? .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: stderrLines, timedOut: false))
                : nil
        }
        let sut = makeSUT(runner: runner)

        // when
        await sut.install()

        // then
        guard case .failed(let stage, let message) = sut.state, stage == .polybridge else {
            Issue.record("expected failed(.polybridge, _), got \(sut.state)")
            return
        }
        // only the last 5 non-empty lines.
        #expect(!message.contains("line 1 "))
        #expect(message.contains("line 8"))
        #expect(message.contains("line 4"))
    }

    @Test func givenPolybridgeInstallTimesOut_whenInstalling_thenStateBecomesUnresolved() async {
        // given
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallRepositoryImplTests.uvExecutable
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
                : nil
        }
        let sut = makeSUT(runner: runner)

        // when
        await sut.install()

        // then
        #expect(sut.state == .unresolved(stage: .polybridge))
    }

    // MARK: checkAgain — read-only, from unresolved and failed(.validate)

    @Test func givenUnresolved_whenCheckAgainPasses_thenStateBecomesInstalled() async {
        // given
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallRepositoryImplTests.uvExecutable
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
                : nil
        }
        let sut = makeSUT(runner: runner)
        await sut.install()
        #expect(sut.state == .unresolved(stage: .polybridge))

        // when — the "installer" has actually finished by the time we check again: no override to
        // `runner` is needed since the plain happy-path runner already answers success for
        // everything else, including this second call to the polybridge executable.
        await sut.checkAgain()

        // then
        #expect(sut.state == .installed)
    }

    @Test func givenUnresolved_whenCheckAgainFails_thenStateStaysUnresolvedAtTheSameStageWithTheMessageRecorded() async {
        // given
        let runner = InstallRepositoryImplTests.makeRunner { call in
            switch call.executable {
            case InstallRepositoryImplTests.uvExecutable:
                .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
            case InstallRepositoryImplTests.ctlPath:
                .success(ProcessOutput(exitCode: 2, stdout: Data(), stderr: "still not there", timedOut: false))
            default: nil
            }
        }
        let sut = makeSUT(runner: runner)
        await sut.install()

        // when
        await sut.checkAgain()

        // then — the only way out of `unresolved` is a passing validation; a failed check keeps the
        // very same stage.
        #expect(sut.state == .unresolved(stage: .polybridge))
        #expect(sut.lastCheckMessage != nil)
    }

    @Test func givenCheckAgainRuns_whenObservingSideEffects_thenNothingIsMutatedBeyondTheStateItself() async {
        // given — "never mutates" here means it never re-runs git/uv/polybridge; the polybridge
        // executable must be hit exactly once (from `install()`), never a second time by
        // `checkAgain()`.
        let polybridgeCalls = LockedBox(0)
        let runner = InstallRepositoryImplTests.makeRunner { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            polybridgeCalls.mutate { $0 += 1 }
            return .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        }
        let sut = makeSUT(runner: runner)
        await sut.install()
        #expect(polybridgeCalls.value == 1)

        // when
        await sut.checkAgain()

        // then
        #expect(polybridgeCalls.value == 1)
    }

    @Test func givenFailedValidate_whenCheckAgainPasses_thenStateBecomesInstalled() async {
        // given
        let taskList = InstallRepositoryImplTests.makeTaskList(refreshAndWait: .failure(.notFound(tool: "polybridge-ctl", searched: [])))
        let sut = makeSUT(taskList: taskList)
        await sut.install()
        guard case .failed(.validate, _) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }

        // when — swap in a task-list repository that now succeeds and retry via checkAgain. Since
        // the repository instance is fixed at construction, this test instead proves the "stays
        // failed(.validate)" half; a fresh SUT below proves the "moves to installed" half.
        await sut.checkAgain()

        // then
        guard case .failed(.validate, _) = sut.state else {
            Issue.record("expected to stay failed(.validate, _), got \(sut.state)")
            return
        }
    }

    @Test func givenFailedValidateWhereTheBarrierNowSucceeds_whenCheckAgainRuns_thenStateBecomesInstalled() async {
        // given — this time the barrier fails only on the *first* pass.
        let taskList = MockTaskListRepository()
        var refreshCallCount = 0
        given(taskList).refreshAndWait().willProduce {
            refreshCallCount += 1
            return refreshCallCount == 1 ? .failure(.notFound(tool: "polybridge-ctl", searched: [])) : .success(())
        }
        let sut = makeSUT(taskList: taskList)
        await sut.install()
        guard case .failed(.validate, _) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }

        // when
        await sut.checkAgain()

        // then
        #expect(sut.state == .installed)
    }

    @Test func givenIdle_whenCheckAgainIsCalled_thenNothingHappens() async {
        // given
        let sut = makeSUT()

        // when
        await sut.checkAgain()

        // then
        #expect(sut.state == .idle)
    }

    // MARK: The running-installer probe

    @Test func givenTheProbeExitsWithAnUnknownCode_whenInstallAnywayIsCalled_thenItCountsAsAMatchAndIsRefused() async {
        // given — force into `unresolved` via a polybridge-stage timeout so `installAnyway()` is
        // reachable, with the probe itself answering an exit code that is neither 0 nor 1.
        let runner = InstallRepositoryImplTests.makeRunner(pgrepExitCode: 2) { call in
            call.executable == InstallRepositoryImplTests.uvExecutable
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
                : nil
        }
        let sut = makeSUT(runner: runner)
        await sut.install()
        #expect(sut.state == .unresolved(stage: .polybridge))

        // when
        let attempted = await sut.installAnyway()

        // then
        #expect(attempted == false)
        #expect(sut.state == .unresolved(stage: .polybridge))
        #expect(sut.installAnywayBlockedMessage != nil)
    }

    @Test func givenTheProbeCleanlyFindsNoMatch_whenInstallAnywayIsCalled_thenItProceeds() async {
        // given — the polybridge stage times out on its first attempt (reaching `unresolved`), then
        // succeeds on the retry `installAnyway()` triggers; the probe itself answers a clean "no
        // match" (exit 1) throughout.
        let polybridgeCalls = LockedBox(0)
        let runner = InstallRepositoryImplTests.makeRunner(pgrepExitCode: 1) { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            let thisCall = polybridgeCalls.value + 1
            polybridgeCalls.mutate { $0 = thisCall }
            return thisCall == 1
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
                : .success(stdout(""))
        }
        let sut = makeSUT(runner: runner)
        await sut.install()
        #expect(sut.state == .unresolved(stage: .polybridge))

        // when
        let attempted = await sut.installAnyway()

        // then — a clean probe never *proves* anything by itself, but it does allow the button to
        // proceed, and the retried polybridge stage now succeeds.
        #expect(attempted == true)
        #expect(sut.state == .installed)
    }

    @Test func givenNotUnresolved_whenInstallAnywayIsCalled_thenItIsRefused() async {
        // given
        let sut = makeSUT()

        // when
        let attempted = await sut.installAnyway()

        // then
        #expect(attempted == false)
        #expect(sut.state == .idle)
    }

    // MARK: reset()

    @Test func givenUnresolved_whenResetIsCalled_thenItIsRefused() async {
        // given
        let runner = InstallRepositoryImplTests.makeRunner { call in
            call.executable == InstallRepositoryImplTests.uvExecutable
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
                : nil
        }
        let sut = makeSUT(runner: runner)
        await sut.install()
        #expect(sut.state == .unresolved(stage: .polybridge))

        // when
        sut.reset()

        // then
        #expect(sut.state == .unresolved(stage: .polybridge))
    }

    @Test func givenRunning_whenResetIsCalled_thenItIsIgnored() async {
        // given — a runner that blocks the polybridge stage until released, so `state` is guaranteed
        // to still be `.running` when `reset()` is called.
        let gate = AsyncGate()
        let runner = InstallRepositoryImplTests.makeRunner { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            gate.waitSync()
            return .success(stdout(""))
        }
        let sut = makeSUT(runner: runner)

        // when
        let installTask = Task { await sut.install() }
        await waitUntil { sut.state == .running(.polybridge) }
        sut.reset()
        let stateWhileRunning = sut.state
        gate.open()
        await installTask.value

        // then
        #expect(stateWhileRunning == .running(.polybridge))
        #expect(sut.state == .installed)
    }

    @Test func givenFailed_whenResetIsCalled_thenStateBecomesIdleAndCapturedStateIsCleared() async {
        // given
        let taskList = InstallRepositoryImplTests.makeTaskList(refreshAndWait: .failure(.notFound(tool: "polybridge-ctl", searched: [])))
        let sut = makeSUT(taskList: taskList)
        await sut.install()
        #expect(sut.lastCheckMessage != nil)

        // when
        sut.reset()

        // then
        #expect(sut.state == .idle)
        #expect(sut.lastCheckMessage == nil)
    }

    // MARK: retry()

    @Test func givenFailedValidate_whenRetried_thenOnlyValidationReRunsNotThePolybridgeInstall() async {
        // given
        let polybridgeCalls = LockedBox(0)
        let taskList = MockTaskListRepository()
        var refreshCallCount = 0
        given(taskList).refreshAndWait().willProduce {
            refreshCallCount += 1
            return refreshCallCount == 1 ? .failure(.notFound(tool: "polybridge-ctl", searched: [])) : .success(())
        }
        let runner = InstallRepositoryImplTests.makeRunner { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            polybridgeCalls.mutate { $0 += 1 }
            return .success(stdout(""))
        }
        let sut = makeSUT(taskList: taskList, runner: runner)
        await sut.install()
        #expect(polybridgeCalls.value == 1)
        guard case .failed(.validate, _) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }

        // when
        await sut.retry()

        // then — validation re-ran (the barrier now succeeds) but the polybridge executable was
        // never invoked a second time.
        #expect(sut.state == .installed)
        #expect(polybridgeCalls.value == 1)
    }
}
