import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - StatisticsRepository

/// Explicit bounded history pages through the public engine interface.
@Mockable
public protocol StatisticsRepository: Sendable {
    func page(since: String, before: String, cursor: String?) async -> Result<StatisticsPage, ToolError>
}

/// Stateless reads preserve the selected managed runtime and recovery boundary.
public struct StatisticsRepositoryImpl: StatisticsRepository {
    private let toolEnvironment: any ToolEnvironmentRepository
    private let stateRecovery: any StateRecoveryRepository
    public init(toolEnvironment: any ToolEnvironmentRepository, stateRecovery: any StateRecoveryRepository) {
        self.toolEnvironment = toolEnvironment; self.stateRecovery = stateRecovery
    }

    public func page(since: String, before: String, cursor: String?) async -> Result<StatisticsPage, ToolError> {
        guard !Task.isCancelled else { return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Statistics cancelled")) }
        let result: Result<StatisticsPage, ToolError> = switch toolEnvironment.ctl() {
        case .success(let client): await client.statisticsPage(since: since, before: before, cursor: cursor)
        case .failure(let error): .failure(error)
        }
        if case .failure(let error) = result, !Task.isCancelled { stateRecovery.report(error) }
        return result
    }
}

/// Missing configuration is unavailable rather than an authoritative empty history.
public struct NullStatisticsRepository: StatisticsRepository {
    public init() {}
    public func page(since _: String, before _: String, cursor _: String?) async -> Result<StatisticsPage, ToolError> {
        .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Statistics unavailable"))
    }
}

public extension GlobalValues {
    /// Engine Statistics history reader.
    @GlobalEntry var statisticsRepository: any StatisticsRepository = NullStatisticsRepository()
}
