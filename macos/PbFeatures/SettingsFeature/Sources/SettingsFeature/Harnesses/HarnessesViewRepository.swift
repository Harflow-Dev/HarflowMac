//
//  HarnessesViewRepository.swift
//  SettingsFeature
//

import Combine
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

    // MARK: Install

    func installStatePublisher() -> AnyPublisher<InstallState, Never> { installRepository.statePublisher() }
    var installState: InstallState { installRepository.state }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { installRepository.lastCheckMessagePublisher() }
    var lastCheckMessage: String? { installRepository.lastCheckMessage }
    func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never> { installRepository.installAnywayBlockedMessagePublisher() }
    var installAnywayBlockedMessage: String? { installRepository.installAnywayBlockedMessage }
    func installDestination() -> String? { installRepository.destination() }
    func install() async { await installRepository.install() }
    func installUvThenPolybridge() async { await installRepository.installUvThenPolybridge() }
    func retry() async { await installRepository.retry() }
    func checkAgain() async { await installRepository.checkAgain() }
    @discardableResult
    func installAnyway() async -> Bool { await installRepository.installAnyway() }
    func reset() { installRepository.reset() }

    func installNeed(for error: ToolError) -> InstallNeed? {
        InstallCommands.installNeed(
            for: error,
            ctl: presence(toolEnvironmentRepository.locator.locate("polybridge-ctl")),
            setup: presence(toolEnvironmentRepository.locator.locate("polybridge-setup"))
        )
    }

    private func presence(_ result: Result<String, ToolError>) -> ToolPresence {
        switch result {
        case .success(let path): .found(path: path)
        case .failure: .notFound
        }
    }
}
