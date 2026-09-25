//
//  InteractiveViewRepository.swift
//  MainWindowFeature
//

import Combine
import Foundation
import PbTerminal
import SwiftEnvironment

// MARK: - InteractiveViewRepository

/// Concrete `InteractiveUseCase` backed by `TerminalSessionRegistry`.
@MainActor
final class InteractiveViewRepository: InteractiveUseCase, @unchecked Sendable {
    
    // MARK: - Private Properties
    
    @GlobalEnvironment(\.terminalSessionRegistry) private var terminalSessionRegistry
    
    // MARK: - Init
    
    init(terminalSessionRegistry: (any TerminalSessionRegistry)? = nil) {
        if let terminalSessionRegistry { self.terminalSessionRegistry = terminalSessionRegistry }
    }
    
    // MARK: - InteractiveUseCase Methods
    
    func sessionsPublisher() -> AnyPublisher<[TerminalSession], Never> { terminalSessionRegistry.sessionsPublisher() }
    func removeSession(_ session: TerminalSession) { terminalSessionRegistry.remove(session) }
}
