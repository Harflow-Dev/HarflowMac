import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - InstallStage

/// One step of the managed runtime pipeline: install or update the runtime, then validate it.
public enum InstallStage: Equatable, Sendable {
    case harflow
    case validate
}

// MARK: - InstallState

/// The install operation's state machine, as `ManagedInstallRepository` projects the managed
/// runtime's state.
public enum InstallState: Equatable, Sendable {
    case idle
    /// `.validate` shows "Checking…"; it can take tens of seconds (`harflow-setup --status`'s
    /// own 90 s cap).
    case running(InstallStage)
    /// Terminal: the named stage failed with a message a person can act on.
    case failed(stage: InstallStage, message: String)
    /// Terminal: validated, and the barrier refresh (`TaskListRepository.refreshAndWait()`)
    /// succeeded.
    case installed
}

// MARK: - InstallRepository

/// The shared managed-runtime install operation and its state.
@Mockable
public protocol InstallRepository: Sendable {

    /// Typed shared managed setup state. Legacy adapters default to ready.
    var setupState: RuntimeSetupState { get }
    func setupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never>

    var state: InstallState { get }
    func statePublisher() -> AnyPublisher<InstallState, Never>

    /// Installs or updates the managed runtime. Runs only from a failed, update-failed or installation-required
    /// runtime, retrying preparation from the start; in any other state, or while an attempt is in flight, it does nothing.
    func install() async
}

// MARK: - NullInstallRepository

public struct NullInstallRepository: InstallRepository {
    public init() {}
    public var state: InstallState { .idle }
    public func statePublisher() -> AnyPublisher<InstallState, Never> { Just(.idle).eraseToAnyPublisher() }
    public func install() async {}
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global install repository.
    @GlobalEntry var installRepository: any InstallRepository = NullInstallRepository()
}
