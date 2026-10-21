import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

private func installVersionInfo(stateRoot: String) -> String {
    "{" +
        "\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1,\"product_version\":\"0.0.1\",\"component\":\"engine\"," +
        "\"state_root\":\"\(stateRoot)\",\"contracts\":{" +
        "\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1},\"setup\":{\"format\":\"harflow.setup\",\"v\":1}," +
        "\"events\":{\"format\":\"harflow.event\",\"v\":1}},\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\",\"version-info.v1\"]," +
        "\"os\":\"darwin\",\"architecture\":\"arm64\"}"
}

@Suite struct InstallRepositoryImplTests {

    // MARK: Fixtures

    static let home = "/Users/fixture"
    static let destination = "/Users/fixture/uv-bin"
    static let uvExecutable = "/usr/local/bin/uv"
    static let gitPath = "/opt/homebrew/bin/git"
    static let pathEnvironment = ["PATH": "/opt/homebrew/bin:/usr/bin:/bin"]

    static var ctlPath: String { destination + "/harflow-ctl" }
    static var setupPath: String { destination + "/harflow-setup" }

    static func uv(binDirectory: String = destination) -> UvResolution { UvResolution(executable: uvExecutable, binDirectory: binDirectory) }

    static func makeLocator(
        overrideDirectory: String? = nil,
        uvToolBin: String? = destination,
        isExecutable: @escaping @Sendable (String) -> Bool = { $0 == InstallRepositoryImplTests.ctlPath || $0 == InstallRepositoryImplTests.setupPath }
    ) -> ToolLocator {
        ToolLocator(overrideDirectory: overrideDirectory, home: home, uvToolBin: uvToolBin, isExecutable: isExecutable)
    }

    /// A `MockToolEnvironmentRepository` already known to have `uv` (so `install()` goes straight to
    /// the harflow stage) and whose `locator` resolves both binaries to `destination` (so
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

    /// The happy-path runner: git check, uv bootstrap, harflow install, the running-installer
    /// probe (clean), and both validation contracts all succeed. Individual tests override the one
    /// call they care about via `override`.
    static func makeRunner(
        pgrepExitCode: Int32 = 1,
        ctlListJSON: String = #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","tasks":[]}"#,
        setupStatusJSON: String = #"{"product":"harflow","format":"harflow.setup","v":1,"product_version":"0.0.1","clients":[]}"#,
        override: (@Sendable (StubProcessRunner.Call) -> Result<ProcessOutput, ToolError>?)? = nil
    ) -> StubProcessRunner {
        StubProcessRunner { call in
            if let overridden = override?(call) { return overridden }
            if call.executable == ctlPath, call.arguments == ["version-info", "--json"] {
                let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
                return .success(stdout(installVersionInfo(stateRoot: root)))
            }
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

    @Test func givenUvAlreadyKnown_whenInstalling_thenItGoesStraightToHarflowAndSucceeds() async {
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
        await sut.installUvThenHarflow()

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
        await sut.installUvThenHarflow()

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
        await sut.installUvThenHarflow()

        // then
        guard case .failed(let stage, let message) = sut.state, stage == .uv else {
            Issue.record("expected failed(.uv, _), got \(sut.state)")
            return
        }
        #expect(message.contains("still couldn't be found"))
    }

    @Test func givenUvBootstrapSucceedsAndUvIsThenFound_whenInstallingUv_thenItContinuesToHarflowAndValidates() async {
        // given — `install()` first sees no `uv` (needsUv); the follow-up `discoverEnvironment()`
        // inside the bootstrap now reports it found, so the continuation should run all the way to
        // `installed` inside the same guarded operation (F.4 "uv-then-harflow continuation").
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
        await sut.installUvThenHarflow()

        // then
        #expect(sut.state == .installed)
    }

    // MARK: harflow stage failures

    @Test func givenHarflowInstallLaunchFails_whenInstalling_thenItFailsAtTheHarflowStage() async {
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
        guard case .failed(let stage, _) = sut.state, stage == .harflow else {
            Issue.record("expected failed(.harflow, _), got \(sut.state)")
            return
        }
    }

    @Test func givenHarflowInstallExitsNonZero_whenInstalling_thenTheMessageIncludesTheStderrTail() async {
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
        guard case .failed(let stage, let message) = sut.state, stage == .harflow else {
            Issue.record("expected failed(.harflow, _), got \(sut.state)")
            return
        }
        // only the last 5 non-empty lines.
        #expect(!message.contains("line 1 "))
        #expect(message.contains("line 8"))
        #expect(message.contains("line 4"))
    }

    @Test func givenHarflowInstallTimesOut_whenInstalling_thenStateBecomesUnresolved() async {
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
        #expect(sut.state == .unresolved(stage: .harflow))
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
        #expect(sut.state == .unresolved(stage: .harflow))

        // when — the "installer" has actually finished by the time we check again: no override to
        // `runner` is needed since the plain happy-path runner already answers success for
        // everything else, including this second call to the harflow executable.
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
        #expect(sut.state == .unresolved(stage: .harflow))
        #expect(sut.lastCheckMessage != nil)
    }

    @Test func givenCheckAgainRuns_whenObservingSideEffects_thenNothingIsMutatedBeyondTheStateItself() async {
        // given — "never mutates" here means it never re-runs git/uv/harflow; the harflow
        // executable must be hit exactly once (from `install()`), never a second time by
        // `checkAgain()`.
        let harflowCalls = LockedBox(0)
        let runner = InstallRepositoryImplTests.makeRunner { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            harflowCalls.mutate { $0 += 1 }
            return .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        }
        let sut = makeSUT(runner: runner)
        await sut.install()
        #expect(harflowCalls.value == 1)

        // when
        await sut.checkAgain()

        // then
        #expect(harflowCalls.value == 1)
    }

    @Test func givenFailedValidate_whenCheckAgainPasses_thenStateBecomesInstalled() async {
        // given
        let taskList = InstallRepositoryImplTests.makeTaskList(refreshAndWait: .failure(.notFound(tool: "harflow-ctl", searched: [])))
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
            return refreshCallCount == 1 ? .failure(.notFound(tool: "harflow-ctl", searched: [])) : .success(())
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
        // given — force into `unresolved` via a harflow-stage timeout so `installAnyway()` is
        // reachable, with the probe itself answering an exit code that is neither 0 nor 1.
        let runner = InstallRepositoryImplTests.makeRunner(pgrepExitCode: 2) { call in
            call.executable == InstallRepositoryImplTests.uvExecutable
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
                : nil
        }
        let sut = makeSUT(runner: runner)
        await sut.install()
        #expect(sut.state == .unresolved(stage: .harflow))

        // when
        let attempted = await sut.installAnyway()

        // then
        #expect(attempted == false)
        #expect(sut.state == .unresolved(stage: .harflow))
        #expect(sut.installAnywayBlockedMessage != nil)
    }

    @Test func givenTheProbeCleanlyFindsNoMatch_whenInstallAnywayIsCalled_thenItProceeds() async {
        // given — the harflow stage times out on its first attempt (reaching `unresolved`), then
        // succeeds on the retry `installAnyway()` triggers; the probe itself answers a clean "no
        // match" (exit 1) throughout.
        let harflowCalls = LockedBox(0)
        let runner = InstallRepositoryImplTests.makeRunner(pgrepExitCode: 1) { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            let thisCall = harflowCalls.value + 1
            harflowCalls.mutate { $0 = thisCall }
            return thisCall == 1
                ? .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
                : .success(stdout(""))
        }
        let sut = makeSUT(runner: runner)
        await sut.install()
        #expect(sut.state == .unresolved(stage: .harflow))

        // when
        let attempted = await sut.installAnyway()

        // then — a clean probe never *proves* anything by itself, but it does allow the button to
        // proceed, and the retried harflow stage now succeeds.
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
        #expect(sut.state == .unresolved(stage: .harflow))

        // when
        sut.reset()

        // then
        #expect(sut.state == .unresolved(stage: .harflow))
    }

    @Test func givenRunning_whenResetIsCalled_thenItIsIgnored() async {
        // given — a runner that blocks the harflow stage until released, so `state` is guaranteed
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
        await waitUntil { sut.state == .running(.harflow) }
        sut.reset()
        let stateWhileRunning = sut.state
        gate.open()
        await installTask.value

        // then
        #expect(stateWhileRunning == .running(.harflow))
        #expect(sut.state == .installed)
    }

    @Test func givenFailed_whenResetIsCalled_thenStateBecomesIdleAndCapturedStateIsCleared() async {
        // given
        let taskList = InstallRepositoryImplTests.makeTaskList(refreshAndWait: .failure(.notFound(tool: "harflow-ctl", searched: [])))
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

    @Test func givenFailedValidate_whenRetried_thenOnlyValidationReRunsNotTheHarflowInstall() async {
        // given
        let harflowCalls = LockedBox(0)
        let taskList = MockTaskListRepository()
        var refreshCallCount = 0
        given(taskList).refreshAndWait().willProduce {
            refreshCallCount += 1
            return refreshCallCount == 1 ? .failure(.notFound(tool: "harflow-ctl", searched: [])) : .success(())
        }
        let runner = InstallRepositoryImplTests.makeRunner { call in
            guard call.executable == InstallRepositoryImplTests.uvExecutable else { return nil }
            harflowCalls.mutate { $0 += 1 }
            return .success(stdout(""))
        }
        let sut = makeSUT(taskList: taskList, runner: runner)
        await sut.install()
        #expect(harflowCalls.value == 1)
        guard case .failed(.validate, _) = sut.state else {
            Issue.record("expected failed(.validate, _), got \(sut.state)")
            return
        }

        // when
        await sut.retry()

        // then — validation re-ran (the barrier now succeeds) but the harflow executable was
        // never invoked a second time.
        #expect(sut.state == .installed)
        #expect(harflowCalls.value == 1)
    }
}
