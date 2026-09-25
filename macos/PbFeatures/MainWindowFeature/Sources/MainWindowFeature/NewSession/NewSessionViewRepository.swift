//
//  NewSessionViewRepository.swift
//  MainWindowFeature
//

import Foundation
import MonitorCore
import PbRepository
import PbTerminal
import SwiftEnvironment

// MARK: - NewSessionViewRepository

/// Concrete `NewSessionUseCase` backed by `TaskActionRepository`, `TerminalSessionRegistry` and
/// `ToolEnvironmentRepository`.
@MainActor
final class NewSessionViewRepository: NewSessionUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.taskActionRepository) private var taskActionRepository
    @GlobalEnvironment(\.terminalSessionRegistry) private var terminalSessionRegistry
    @GlobalEnvironment(\.toolEnvironmentRepository) private var toolEnvironmentRepository
    
    // MARK: - Init
    
    init(
        taskActionRepository: (any TaskActionRepository)? = nil,
        terminalSessionRegistry: (any TerminalSessionRegistry)? = nil,
        toolEnvironmentRepository: (any ToolEnvironmentRepository)? = nil
    ) {
        if let taskActionRepository { self.taskActionRepository = taskActionRepository }
        if let terminalSessionRegistry { self.terminalSessionRegistry = terminalSessionRegistry }
        if let toolEnvironmentRepository { self.toolEnvironmentRepository = toolEnvironmentRepository }
    }
    
    // MARK: - NewSessionUseCase Methods
    
    /// Ported verbatim from the old `NewSessionSheet.start()` (`MainView.swift:144-150`): expand
    /// `~`, then require an absolute path to an existing directory.
    func resolvedRepoPath(_ input: String) -> String? {
        let path = (input as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return path
    }
    
    func run(_ request: RunRequest) async throws -> String {
        try await taskActionRepository.run(request)
    }
    
    func startInteractive(backend: String, repo: String) -> Result<TerminalSession, StartInteractiveError> {
        terminalSessionRegistry.startInteractive(backend: backend, repo: repo, environment: toolEnvironmentRepository.environment())
    }
}
