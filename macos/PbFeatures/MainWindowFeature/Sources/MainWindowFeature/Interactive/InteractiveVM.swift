//
//  InteractiveVM.swift
//  MainWindowFeature
//

import Combine
import Foundation
import Mockable
import PbCommon
import PbTerminal
import PbUtilities

// MARK: - InteractiveUseCase

/// The interactive-terminal screen's data needs over `TerminalSessionRegistry`.
@Mockable
@MainActor
protocol InteractiveUseCase: Sendable {
    func sessionsPublisher() -> AnyPublisher<[TerminalSession], Never>
    func removeSession(_ session: TerminalSession)
}

// MARK: - InteractiveRouting

/// The interactive-terminal screen performs no navigation of its own: "Close" removes the session
/// and leaves the current selection untouched, exactly as the app target's old
/// `AppModel.removeSession(_:)` did. Declared (empty) for the same reason every screen declares one —
/// consistency with the chain `Coordinator → NavigationView → View → VM → UseCase → ViewRepository` —
/// not because this screen needs it today.
@Mockable
@MainActor
protocol InteractiveRouting: Sendable {}

// MARK: - InteractiveVM

/// View model for the interactive-terminal screen, ported from the app target's `MainView.swift`'s
/// `InteractiveView` with no behaviour change.
@Observable
@MainActor
final class InteractiveVM: InteractiveViewModel {
    
    // MARK: - InteractiveViewModel Properties
    
    let sessionID: UUID
    private(set) var session: TerminalSession?
    
    // MARK: - Private Properties
    
    @ObservationIgnored let useCase: any InteractiveUseCase
    @ObservationIgnored let routing: any InteractiveRouting
    @ObservationIgnored var cancellables = Set<AnyCancellable>()
    @ObservationIgnored var didSubscribe = false
    
    // MARK: - Init
    
    init(sessionID: UUID, useCase: any InteractiveUseCase, routing: any InteractiveRouting) {
        self.sessionID = sessionID
        self.useCase = useCase
        self.routing = routing
    }
    
    // MARK: - InteractiveViewModel Methods
    
    func didAppear() {
        subscribeIfNeeded()
    }
    
    /// Idempotent teardown (root AGENTS.md rule 7): cancels the sessions subscription and resets
    /// `didSubscribe` so a reappearing screen subscribes again.
    func didDisappear() {
        cancellables.removeAll()
        didSubscribe = false
    }
    
    func didTapEndSession() {
        session?.terminate()
    }
    
    func didTapCloseSession() {
        guard let session else { return }
        useCase.removeSession(session)
    }
    
    // MARK: - Private Methods
    
    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        
        useCase.sessionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                session = sessions.first { $0.id == sessionID }
            }
            .store(in: &cancellables)
    }
}
