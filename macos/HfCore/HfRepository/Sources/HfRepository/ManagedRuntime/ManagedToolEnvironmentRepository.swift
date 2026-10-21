import Combine
import Foundation
import MonitorCore

// MARK: - ManagedToolEnvironmentRepository

/// Generation-bound managed tooling. The immutable selected home never adopts ambient runtimes.
public final class ManagedToolEnvironmentRepository: ToolEnvironmentRepository, @unchecked Sendable {
    public let home: String
    private let layout: ManagedRuntimeLayout
    private let coordinator: ManagedRuntimeCoordinator
    private let baseEnvironment: [String: String]
    private let runner: any ProcessRunning

    public init(coordinator: ManagedRuntimeCoordinator, layout: ManagedRuntimeLayout,
                baseEnvironment: [String: String], runner: any ProcessRunning = ProcessRunner()) {
        self.coordinator = coordinator
        self.layout = layout
        self.home = layout.home
        self.baseEnvironment = baseEnvironment
        self.runner = runner
    }

    public var tasksDirectory: String { layout.tasksDirectory }
    public var locator: ToolLocator {
        // ToolLocator is retained for presentation/legacy APIs; ctl/setup below never resolve through it.
        let directory: String? = if case .ready(let ready) = coordinator.state {
            (ready.ctlExecutable as NSString).deletingLastPathComponent
        } else { nil }
        return ToolLocator(overrideDirectory: directory, home: home, uvToolBin: nil,
                           isExecutable: { path in directory != nil && (path as NSString).deletingLastPathComponent == directory
                               && FileManager.default.isExecutableFile(atPath: path)
                           })
    }

    public var discovery: DiscoveryResult { DiscoveryResult(loginPath: environment()["PATH"], uv: nil) }
    public func discoveryPublisher() -> AnyPublisher<DiscoveryResult, Never> {
        coordinator.statePublisher()
.map { [weak self] _ in self?.discovery ?? DiscoveryResult(loginPath: nil, uv: nil) }
            .removeDuplicates()
.eraseToAnyPublisher()
    }

    public func discoverEnvironment() async -> DiscoveryResult {
        _ = await coordinator.ensureReady()
        return discovery
    }

    public func environment(toolDirectory _: String?) -> [String: String] {
        if case .ready(let ready) = coordinator.state { return ready.environment }
        var result = LaunchEnvironment.build(base: baseEnvironment, loginPath: baseEnvironment["PATH"], toolDirectory: layout.binDirectory)
        result["HOME"] = home
        result["HARFLOW_STATE_ROOT"] = layout.stateRoot
        return result
    }

    public func ctl() -> Result<CtlClient, ToolError> {
        snapshot().map { ready in
            CtlClient(executable: ready.ctlExecutable, environment: ready.environment, runner: runner,
                      compatibilityContext: RuntimeCompatibilityContext(expectedStateRoot: layout.stateRoot))
        }
    }

    public func setup() -> Result<SetupClient, ToolError> {
        snapshot().map { ready in
            SetupClient(executable: ready.setupExecutable, environment: ready.environment, runner: runner,
                        compatibilityContext: RuntimeCompatibilityContext(expectedStateRoot: layout.stateRoot))
        }
    }

    private func snapshot() -> Result<ManagedRuntimeReady, ToolError> {
        switch coordinator.state {
        case .ready(let ready): .success(ready)
        case .preparing: .failure(.refused(code: "managed_runtime_preparing", message: "Preparing the managed Harflow runtime…"))
        case .failed(let message): .failure(.refused(code: "managed_runtime_failed", message: message))
        }
    }
}
