import Combine
import Foundation
import MonitorCore

// MARK: - ManagedInstallRepository

/// Shared install-status adapter. Only this explicit retry owner restarts the task-list watcher.
public final class ManagedInstallRepository: InstallRepository, @unchecked Sendable {
    private let coordinator: ManagedRuntimeCoordinator
    private let taskListRepository: any TaskListRepository
    private let retryOwner = RetryOwner()
    private enum Notice: Equatable {
        case none
        case installed(String)
        case dismissedFailure(String)
    }

    private let notice = CurrentValueSubject<Notice, Never>(.none)

    public init(coordinator: ManagedRuntimeCoordinator, taskListRepository: any TaskListRepository) {
        self.coordinator = coordinator
        self.taskListRepository = taskListRepository
    }

    public var setupState: RuntimeSetupState { Self.setupState(coordinator.state) }
    public func setupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never> {
        coordinator.statePublisher().map(Self.setupState).removeDuplicates().eraseToAnyPublisher()
    }

    private static func setupState(_ state: ManagedRuntimeState) -> RuntimeSetupState {
        switch state {
        case .preparing: .checking
        case .installationRequired(let installed, let required): .installationRequired(installedVersion: installed, requiredVersion: required)
        case .installing: .installing
        case .updating(let installed, let required): .updating(installedVersion: installed, requiredVersion: required)
        case .updateFailed(let message, let installed, let required): .updateFailed(message: message, installedVersion: installed, requiredVersion: required)
        case .failed(let message): .failed(message)
        case .ready: .ready
        }
    }

    public var state: InstallState { Self.installState(coordinator.state, notice: notice.value) }
    public func statePublisher() -> AnyPublisher<InstallState, Never> {
        coordinator.statePublisher()
.combineLatest(notice)
            .map { Self.installState($0, notice: $1) }
.removeDuplicates()
.eraseToAnyPublisher()
    }

    public var lastCheckMessage: String? { if case .failed(let message) = coordinator.state { message } else { nil } }
    public func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> {
        coordinator.statePublisher()
.map { state -> String? in
            if case .failed(let message) = state { return message }
            return nil
        }
.removeDuplicates()
.eraseToAnyPublisher()
    }

    public var installAnywayBlockedMessage: String? { nil }
    public func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
    public func destination() -> String? { nil }
    public func install() async { await retry() }
    public func installUvThenHarflow() async {}
    public func checkAgain() async { await retry() }
    public func installAnyway() async -> Bool { false }
    public func reset() {
        switch coordinator.state {
        case .ready:
            notice.send(.none)
        case .failed(let message), .updateFailed(let message, _, _):
            notice.send(.dismissedFailure(message))
        default: break
        }
    }

    public func retry() async {
        guard await retryOwner.claim(isFailed: { [coordinator] in
            if case .failed = coordinator.state { return true }
            if case .updateFailed = coordinator.state { return true }
            if case .installationRequired = coordinator.state { return true }
            return false
        }) else { return }
        notice.send(.none)
        if case .success(let ready) = await coordinator.retry() {
            notice.send(.installed(ready.generationDirectory))
            taskListRepository.runtimeBecameReady()
        }
        await retryOwner.finish()
    }

    private static func installState(_ state: ManagedRuntimeState, notice: Notice) -> InstallState {
        switch state {
        case .preparing: .running(.validate)
        case .installing, .updating: .running(.harflow)
        case .updateFailed(let message, _, _): notice == .dismissedFailure(message) ? .idle : .failed(stage: .harflow, message: message)
        case .installationRequired: .idle
        case .ready(let ready): notice == .installed(ready.generationDirectory) ? .installed : .idle
        case .failed(let message): notice == .dismissedFailure(message) ? .idle : .failed(stage: .harflow, message: message)
        }
    }

    private actor RetryOwner {
        private var busy = false
        func claim(isFailed: @Sendable () -> Bool) -> Bool {
            guard !busy, isFailed() else { return false }
            busy = true
            return true
        }

        func finish() { busy = false }
    }
}
