//
//  HarnessesViewRepository.swift
//  SettingsFeature
//

import Foundation
import MonitorCore
import PbRepository
import SwiftEnvironment

// MARK: - HarnessesViewRepository

/// Concrete `HarnessesUseCase` backed by `HarnessRepository`.
@MainActor
final class HarnessesViewRepository: HarnessesUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.harnessRepository) private var harnessRepository
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    
    // MARK: - Init
    
    init(
        harnessRepository: (any HarnessRepository)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil
    ) {
        if let harnessRepository { self.harnessRepository = harnessRepository }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
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
}
