//
//  HarnessesViewRepository.swift
//  SettingsFeature
//

import Combine
import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

// MARK: - HarnessesViewRepository

/// Concrete `HarnessesUseCase` backed by `HarnessRepository`.
@MainActor
final class HarnessesViewRepository: HarnessesUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.qualificationRepository) private var qualificationRepository
    @GlobalEnvironment(\.backendsRepository) private var backendsRepository
    func qualificationSession() -> QualificationSession { QualificationSession(repository: qualificationRepository) }
    func qualificationBackends() async throws -> [String] {
        await backendsRepository.refresh()
        guard backendsRepository.catalog.state == .available else {
            throw ToolError.unreadable(tool: "harflow-ctl backends", exitCode: 0, stderr: "Harness qualification discovery is unavailable. Refresh to retry.")
        }
        return backendsRepository.catalog.entries.map(\.backend)
    }

    @GlobalEnvironment(\.harnessRepository) private var harnessRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    @GlobalEnvironment(\.installRepository) private var installRepository

    // MARK: - Init

    init(
        harnessRepository: (any HarnessRepository)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil,
        installRepository: (any InstallRepository)? = nil
    ) {
        if let harnessRepository { self.harnessRepository = harnessRepository }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
        if let installRepository { self.installRepository = installRepository }
    }
    
    // MARK: - HarnessesUseCase Methods
    
    func status() async -> Result<SetupDocument, ToolError> {
        await harnessRepository.status()
    }
    
    func perform(_ action: SetupClient.Action, client: String?, using setupClient: SetupClient) async -> Result<SetupDocument, ToolError> {
        await harnessRepository.perform(action, client: client, using: setupClient)
    }
    
    /// The one lookup an action uses: `run` checks it before entering the busy state and then runs
    /// the same client, as the original did.
    func locate() -> Result<SetupClient, ToolError> {
        toolEnvironmentRepository.setup()
    }

    // MARK: Runtime readiness

    var runtimeSetupState: RuntimeSetupState { installRepository.setupState }
    func runtimeSetupPublisher() -> AnyPublisher<RuntimeSetupState, Never> { installRepository.setupStatePublisher() }
}
