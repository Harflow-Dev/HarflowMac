import Combine
import Foundation
import HfCommon
import MonitorCore
import SwiftUI

// MARK: - ConnectionStatusViewModel

@MainActor
protocol ConnectionStatusViewModel: ViewModel {
    var isConnected: Bool { get }
    var helpText: String { get }
    func didAppear()
    func didDisappear()
}

// MARK: - ConnectionStatusVM

@Observable
@MainActor
final class ConnectionStatusVM: ConnectionStatusViewModel {
    private(set) var isConnected: Bool
    private(set) var helpText: String

    @ObservationIgnored private let useCase: any SidebarUseCase
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var latestHasListed: Bool
    @ObservationIgnored private var latestErrorMessage: String?

    init(useCase: any SidebarUseCase) {
        self.useCase = useCase
        self.latestHasListed = useCase.hasListed
        self.latestErrorMessage = useCase.listError?.message
        self.isConnected = latestHasListed && latestErrorMessage == nil
        self.helpText = latestErrorMessage ?? useCase.connectionLine
    }

    func didAppear() {
        guard !didSubscribe else { return }
        didSubscribe = true

        useCase.listErrorPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] error in
                guard let self else { return }
                latestErrorMessage = error?.message
                updatePresentation()
            }
            .store(in: &cancellables)

        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] hasListed in
                guard let self else { return }
                latestHasListed = hasListed
                updatePresentation()
            }
            .store(in: &cancellables)

        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updatePresentation() }
            .store(in: &cancellables)

        updatePresentation()
    }

    func didDisappear() {
        guard didSubscribe else { return }
        didSubscribe = false
        cancellables.removeAll()
    }

    private func updatePresentation() {
        let nextIsConnected = latestHasListed && latestErrorMessage == nil
        if isConnected != nextIsConnected { isConnected = nextIsConnected }
        let nextHelpText = latestErrorMessage ?? useCase.connectionLine
        if helpText != nextHelpText { helpText = nextHelpText }
    }
}
