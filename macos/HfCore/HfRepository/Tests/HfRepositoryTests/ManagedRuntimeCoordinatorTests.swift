import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite("Managed runtime coordinator", .serialized)
struct ManagedRuntimeCoordinatorTests {
    private final class ControlledInstaller: ManagedRuntimeInstalling, @unchecked Sendable {
        let ready: ManagedRuntimeReady
        let gate: AsyncGate?
        let lock = NSLock()
        private(set) var callCount = 0
        var failures: [Bool]
        let checkExistingFailure: Bool

        init(ready: ManagedRuntimeReady, gate: AsyncGate? = nil, failures: [Bool] = [], checkExistingFailure: Bool = false) {
            self.ready = ready
            self.gate = gate
            self.failures = failures
            self.checkExistingFailure = checkExistingFailure
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        var currentCallCount: Int { withLock { callCount } }

        func prepare() async throws -> ManagedRuntimeReady {
            let shouldFail = withLock {
                callCount += 1
                return failures.isEmpty ? false : failures.removeFirst()
            }
            gate?.waitSync()
            if shouldFail { throw ManagedRuntimeFailure("fixture acquisition failed") }
            return ready
        }

        func checkExisting() async throws -> ManagedRuntimeAvailability {
            if checkExistingFailure { throw ManagedRuntimeFailure("fixture acquisition failed") }
            withLock { callCount += 1 }
            gate?.waitSync()
            return .ready(ready)
        }
    }

    private struct InstallationRequiredInstaller: ManagedRuntimeInstalling {
        let ready: ManagedRuntimeReady
        let requiredVersion: String

        func prepare() async throws -> ManagedRuntimeReady { ready }

        func checkExisting() async throws -> ManagedRuntimeAvailability {
            .requiresInstallation(installedVersion: "0.0.1", requiredVersion: requiredVersion)
        }
    }

    private func ready() -> ManagedRuntimeReady {
        ManagedRuntimeReady(generationDirectory: "/tmp/managed-runtime-generation", environment: [
            "HOME": "/tmp/managed-runtime-home", "HARFLOW_STATE_ROOT": "/tmp/managed-runtime-home/.harflow"
        ])
    }

    @Test func givenConcurrentReadinessCallers_whenOneAttemptIsBlocked_thenAllJoinThatAttempt() async {
        // given
        let gate = AsyncGate()
        let installer = ControlledInstaller(ready: ready(), gate: gate)
        let coordinator = ManagedRuntimeCoordinator(installer: installer)

        // when
        let first = Task { await coordinator.ensureReady() }
        await waitUntil { installer.currentCallCount == 1 }
        let second = Task { await coordinator.ensureReady() }
        gate.open()
        let results = await [first.value, second.value]

        // then
        #expect(installer.currentCallCount == 1)
        #expect(results.allSatisfy { if case .success = $0 { true } else { false } })
        #expect(coordinator.state == .ready(ready()))
    }

    @Test func givenExistingRuntimeNeedsInstallation_whenEnsuringReadiness_thenItDoesNotAcquireImplicitly() async {
        // given
        let installer = InstallationRequiredInstaller(ready: ready(), requiredVersion: "0.0.2")
        let coordinator = ManagedRuntimeCoordinator(installer: installer)
        let repository = ManagedInstallRepository(coordinator: coordinator, taskListRepository: NullTaskListRepository())

        // when
        let result = await coordinator.ensureReady()

        // then
        guard case .failure(.refused(let code, _)) = result else {
            Issue.record("expected explicit installation requirement")
            return
        }
        #expect(code == "managed_runtime_install_required")
        #expect(coordinator.state == .installationRequired(installedVersion: "0.0.1", requiredVersion: "0.0.2"))
        #expect(repository.setupState == .installationRequired(installedVersion: "0.0.1", requiredVersion: "0.0.2"))
    }

    @Test func givenStartupCallerIsCancelled_whenTheSharedAttemptContinues_thenASecondCallerStillJoinsIt() async {
        // given
        let gate = AsyncGate()
        let installer = ControlledInstaller(ready: ready(), gate: gate)
        let coordinator = ManagedRuntimeCoordinator(installer: installer)
        let cancelledCaller = Task { await coordinator.ensureReady() }
        await waitUntil { installer.currentCallCount == 1 }

        // when
        cancelledCaller.cancel()
        let survivingCaller = Task { await coordinator.ensureReady() }
        gate.open()
        _ = await survivingCaller.value
        _ = await cancelledCaller.value

        // then
        #expect(installer.currentCallCount == 1)
        #expect(coordinator.state == .ready(ready()))
    }

    @Test func givenAnAcquisitionFailure_whenReadinessIsRetriedWithoutExplicitRetry_thenFailureRemainsRetained() async {
        // given
        let installer = ControlledInstaller(ready: ready(), checkExistingFailure: true)
        let coordinator = ManagedRuntimeCoordinator(installer: installer)

        // when
        let first = await coordinator.ensureReady()
        let ordinaryPoll = await coordinator.ensureReady()

        // then
        guard case .failure = first, case .failure = ordinaryPoll else {
            Issue.record("expected both readiness calls to retain the failure")
            return
        }
        #expect(installer.currentCallCount == 0)
        if case .failed(let message) = coordinator.state {
            #expect(message == "fixture acquisition failed")
        } else {
            Issue.record("expected retained failed state")
        }
    }

    @Test func givenRetainedFailure_whenExplicitRetrySucceeds_thenOnlyRetryStartsANewAttempt() async {
        // given
        let installer = ControlledInstaller(ready: ready(), failures: [false], checkExistingFailure: true)
        let coordinator = ManagedRuntimeCoordinator(installer: installer)
        _ = await coordinator.ensureReady()

        // when
        let result = await coordinator.retry()

        // then
        guard case .success(let actual) = result else {
            Issue.record("expected explicit retry to succeed")
            return
        }
        #expect(actual == ready())
        #expect(installer.currentCallCount == 1)
        #expect(coordinator.state == .ready(ready()))
    }

    @Test func givenRetainedFailure_whenConcurrentExplicitRetriesStart_thenTheyShareOnePreparation() async {
        // given
        let gate = AsyncGate()
        let installer = ControlledInstaller(
            ready: ready(), gate: gate, failures: [false], checkExistingFailure: true
        )
        let coordinator = ManagedRuntimeCoordinator(installer: installer)
        _ = await coordinator.ensureReady()

        // when
        let first = Task { await coordinator.retry() }
        await waitUntil { installer.currentCallCount == 1 }
        let second = Task { await coordinator.retry() }
        gate.open()
        let results = await [first.value, second.value]

        // then
        #expect(installer.currentCallCount == 1)
        #expect(results.allSatisfy { if case .success = $0 { true } else { false } })
        #expect(coordinator.state == .ready(ready()))
    }

    @Test func givenInitialReadinessSucceeds_whenInstallSurfaceSettles_thenItDoesNotRestartTheWatcher() async {
        // given
        let gate = AsyncGate()
        let installer = ControlledInstaller(ready: ready(), gate: gate)
        let coordinator = ManagedRuntimeCoordinator(installer: installer)
        let taskList = MockTaskListRepository()
        let settingsChanges = LockedBox(0)
        given(taskList).settingsChanged().willProduce { settingsChanges.mutate { $0 += 1 } }
        let repository = ManagedInstallRepository(coordinator: coordinator, taskListRepository: taskList)

        // when
        let attempt = Task { await coordinator.ensureReady() }
        await waitUntil { installer.currentCallCount == 1 }
        gate.open()
        await attempt.value

        // then — automatic initial readiness may publish installed, but it never owns the retry
        // restart hook reserved for an explicit retry from retained failure.
        #expect(repository.state == .installed)
        #expect(settingsChanges.value == 0)
    }

    @Test func givenRetainedInstallFailure_whenExplicitRetrySucceeds_thenWatcherRestartsExactlyOnce() async {
        // given
        let installer = ControlledInstaller(ready: ready(), failures: [false], checkExistingFailure: true)
        let coordinator = ManagedRuntimeCoordinator(installer: installer)
        let taskList = MockTaskListRepository()
        let settingsChanges = LockedBox(0)
        given(taskList).runtimeBecameReady().willProduce { settingsChanges.mutate { $0 += 1 } }
        let repository = ManagedInstallRepository(coordinator: coordinator, taskListRepository: taskList)
        _ = await coordinator.ensureReady()
        #expect(repository.state == .failed(stage: .harflow, message: "fixture acquisition failed"))

        // when
        await repository.retry()

        // then
        #expect(repository.state == .installed)
        #expect(settingsChanges.value == 1)
    }
}
