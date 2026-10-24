import Combine
import Foundation

// MARK: - RuntimeSetupState

/// Runtime setup is independent of task-store compatibility and connection status.
public enum RuntimeSetupState: Equatable, Sendable {
    case checking
    case installationRequired(installedVersion: String?, requiredVersion: String)
    case installing
    case updating(installedVersion: String, requiredVersion: String)
    case updateFailed(message: String, installedVersion: String, requiredVersion: String)
    case failed(String)
    case ready

    public var isReady: Bool { self == .ready }
    public var isBusy: Bool {
        switch self {
        case .checking, .installing, .updating: true
        default: false
        }
    }

    public var actionTitle: String? {
        switch self {
        case .installationRequired(let installed, _): installed == nil ? "Install required components" : "Update required components"
        case .failed: "Retry installation"
        case .updateFailed: "Retry update"
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .checking: "Checking Harflow runtime…"
        case .installationRequired(let installed, _): installed == nil ? "Prepare Harflow" : "Update Harflow runtime"
        case .installing: "Preparing Harflow…"
        case .updating: "Updating Harflow…"
        case .updateFailed: "Update did not finish"
        case .failed: "Setup did not finish"
        case .ready: "Harflow runtime is ready"
        }
    }

    public var detail: String {
        switch self {
        case .checking: return "Checking the managed installation on this Mac."
        case .installationRequired(let installed, let required):
            if let installed { return "Installed engine \(installed). This app requires engine \(required)." }
            return "Install the components Harflow needs to run. Required engine: \(required)."
        case .installing: return "Installing required components for this app."
        case .updating(let installed, let required):
            return "Installing the update from engine \(installed) to \(required). "
                + "Your task history is preserved during the update."
        case .updateFailed(let message, let installed, let required):
            return "Installed engine \(installed); required engine \(required). "
                + "Your history and existing installation have been kept. \(message)"
        case .failed(let message): return message
        case .ready: return "MCP registrations are managed separately in Harnesses."
        }
    }
}

public extension InstallRepository {
    var setupState: RuntimeSetupState { .ready }
    func setupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never> { Just(setupState).eraseToAnyPublisher() }
}
