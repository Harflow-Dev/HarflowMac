import Combine
import Foundation
import HfUtilities
import MonitorCore

// MARK: - ManagedRuntimeState

/// Shared readiness surface. Failure remains retained until the user explicitly retries.
public enum ManagedRuntimeState: Equatable, Sendable {
    case preparing
    case installationRequired(installedVersion: String?, requiredVersion: String)
    case installing
    case updating(installedVersion: String, requiredVersion: String)
    case updateFailed(message: String, installedVersion: String, requiredVersion: String)
    case ready(ManagedRuntimeReady)
    case failed(String)
}

// MARK: - ManagedRuntimeCoordinator

/// All startup consumers await one attempt, including its failure; ordinary polls never reacquire.
public final class ManagedRuntimeCoordinator: @unchecked Sendable {
    @Subjected private var stateValue: ManagedRuntimeState = .preparing
    private let attempt: Attempt

    public init(installer: any ManagedRuntimeInstalling) {
        self.attempt = Attempt(installer: installer)
    }

    public var state: ManagedRuntimeState { stateValue }
    public func statePublisher() -> AnyPublisher<ManagedRuntimeState, Never> { $stateValue.removeDuplicates().eraseToAnyPublisher() }

    public func ensureReady() async -> Result<ManagedRuntimeReady, ToolError> {
        await attempt.run(retry: false, publish: publish)
    }

    public func retry() async -> Result<ManagedRuntimeReady, ToolError> {
        await attempt.run(retry: true, publish: publish)
    }

    private func publish(_ state: ManagedRuntimeState) { stateValue = state }

    private actor Attempt {
        private let installer: any ManagedRuntimeInstalling
        private var task: Task<Result<ManagedRuntimeReady, ToolError>, Never>?
        private var installedVersion: String?
        private var requiredVersion = HarflowVersion.current
        private var result: Result<ManagedRuntimeReady, ToolError>?

        init(installer: any ManagedRuntimeInstalling) { self.installer = installer }

        func run(retry: Bool, publish: @escaping @Sendable (ManagedRuntimeState) -> Void) async -> Result<ManagedRuntimeReady, ToolError> {
            if let task { return await task.value }
            if let result {
                if !retry { return result }
                if case .success = result { return result }
            }
            if retry, let installedVersion {
                publish(.updating(installedVersion: installedVersion, requiredVersion: requiredVersion))
            } else { publish(retry ? .installing : .preparing) }
            let installer = installer
            let next = Task.detached { [self] () -> Result<ManagedRuntimeReady, ToolError> in
                let settled: Result<ManagedRuntimeReady, ToolError>
                do {
                    if retry {
                        settled = .success(try await installer.prepare())
                    } else {
                        switch try await installer.checkExisting() {
                        case .ready(let ready): settled = .success(ready)
                        case .requiresInstallation(let installed, let required):
                            let error = ToolError.refused(code: "managed_runtime_install_required",
                                                          message: "Install the required Harflow runtime components to continue.")
                            await installationRequired(installed: installed, required: required, error: error, publish: publish)
                            return .failure(error)
                        }
                    }
                } catch {
                    let message = (error as? ManagedRuntimeFailure)?.message ?? (error as? ToolError)?.message ?? error.localizedDescription
                    settled = .failure(.refused(code: "managed_runtime_failed", message: message))
                }
                await complete(settled, publish: publish)
                return settled
            }
            task = next
            return await next.value
        }

        private func installationRequired(installed: String?, required: String, error: ToolError, publish: @Sendable (ManagedRuntimeState) -> Void) {
            installedVersion = installed
            requiredVersion = required
            result = .failure(error)
            task = nil
            publish(.installationRequired(installedVersion: installed, requiredVersion: required))
        }

        private func complete(_ settled: Result<ManagedRuntimeReady, ToolError>,
                              publish: @Sendable (ManagedRuntimeState) -> Void) {
            result = settled
            task = nil
            if case .failure(let error) = settled, let installedVersion {
                publish(.updateFailed(message: error.message, installedVersion: installedVersion, requiredVersion: requiredVersion))
                return
            }
            switch settled {
            case .success(let ready): publish(.ready(ready))
            case .failure(.refused(code: "managed_runtime_failed", message: let message)): publish(.failed(message))
            case .failure(let error): publish(.failed(error.message))
            }
        }
    }
}
