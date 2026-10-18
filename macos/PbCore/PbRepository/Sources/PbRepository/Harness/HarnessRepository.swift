import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - HarnessRepository

/// `polybridge-setup` status/install/remove for the Harnesses screen — the same results
/// `SettingsView`'s `HarnessSettings` gets today (`SettingsView.swift:118-148`).
@Mockable
public protocol HarnessRepository: Sendable {
    func status() async -> Result<SetupDocument, ToolError>
    func perform(_ action: SetupClient.Action, client: String?) async -> Result<SetupDocument, ToolError>
    /// Runs `action` with an already-located `polybridge-setup`, so the client that was checked is
    /// the one that runs (the original located once per action).
    func perform(_ action: SetupClient.Action, client: String?, using setupClient: SetupClient) async -> Result<SetupDocument, ToolError>
}

// MARK: - HarnessRepositoryImpl

public final class HarnessRepositoryImpl: HarnessRepository, @unchecked Sendable {
    private let toolEnvironment: any ToolEnvironmentRepository

    public init(toolEnvironment: any ToolEnvironmentRepository) {
        self.toolEnvironment = toolEnvironment
    }

    public func status() async -> Result<SetupDocument, ToolError> {
        await perform(.status, client: nil)
    }

    public func perform(_ action: SetupClient.Action, client: String?) async -> Result<SetupDocument, ToolError> {
        switch toolEnvironment.setup() {
        case .failure(let error): .failure(error)
        case .success(let setupClient): await setupClient.perform(action, client: client)
        }
    }

    public func perform(_ action: SetupClient.Action, client: String?, using setupClient: SetupClient) async -> Result<SetupDocument, ToolError> {
        await setupClient.perform(action, client: client)
    }
}

// MARK: - NullHarnessRepository

public struct NullHarnessRepository: HarnessRepository {
    public init() {}
    public func status() async -> Result<SetupDocument, ToolError> { .failure(.notFound(tool: "polybridge-setup", searched: [])) }
    public func perform(_: SetupClient.Action, client _: String?) async -> Result<SetupDocument, ToolError> {
        .failure(.notFound(tool: "polybridge-setup", searched: []))
    }

    public func perform(_: SetupClient.Action, client _: String?, using _: SetupClient) async -> Result<SetupDocument, ToolError> {
        .failure(.notFound(tool: "polybridge-setup", searched: []))
    }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global harness repository.
    @GlobalEntry var harnessRepository: any HarnessRepository = NullHarnessRepository()
}
