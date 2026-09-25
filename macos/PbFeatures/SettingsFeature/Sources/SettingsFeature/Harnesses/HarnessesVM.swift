//
//  HarnessesVM.swift
//  SettingsFeature
//
//  Ported from the app target's `SettingsView.swift` (`HarnessSettings`). The confirmation dialog
//  becomes a `ViewEvent.dialog` (decision 10) with identical copy. **Existing issue preserved on
//  purpose**: after a successful action, only that row updates — see `run(_:_:)` below and the
//  settled plan's "Existing issues" section. No `Routing` protocol: this screen has no navigation.
//

import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon

// MARK: - HarnessesUseCase

/// `polybridge-setup` status/install/remove, straight over `HarnessRepository`.
@Mockable
@MainActor
protocol HarnessesUseCase: Sendable {
    func status() async -> Result<SetupDocument, ToolError>
    func perform(_ action: SetupClient.Action, client: String?, using setupClient: SetupClient) async -> Result<SetupDocument, ToolError>
    /// Locates `polybridge-setup` only, mirroring the original's `model.setup()` pre-check in `run`
    /// (`SettingsView.swift:134`) — checked BEFORE entering the busy (`workingKey`) state, so a
    /// locator failure there is a silent no-op (item 8). `load()`'s own locator failure still shows
    /// through `status()`'s ordinary failure path, unchanged.
    func locate() -> Result<SetupClient, ToolError>
}

// MARK: - HarnessesVM

/// View model for the Harnesses settings tab.
@Observable
@MainActor
final class HarnessesVM: HarnessesViewModel {
    
    // MARK: - HarnessesViewModel Properties
    
    private(set) var rows: [HarnessRow] = []
    private(set) var serverPath: String?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var workingKey: String?
    var isRefreshDisabled: Bool { isLoading || workingKey != nil }
    
    // MARK: - Private Properties
    
    @ObservationIgnored private let useCase: any HarnessesUseCase
    
    // MARK: - Init
    
    init(useCase: any HarnessesUseCase) {
        self.useCase = useCase
    }
    
    // MARK: - HarnessesViewModel Methods
    
    func didAppear() {
        Task { [weak self] in await self?.load() }
    }
    
    func didDisappear() {}
    
    func didTapRefresh() {
        Task { [weak self] in await self?.load() }
    }
    
    func didTapInstall(_ row: HarnessRow) {
        publishDialog(
            "Install polybridge into \(row.displayName)?",
            description: "This runs polybridge-setup, which edits \(row.displayName)'s own configuration."
        ) {
            AlertAction(title: "Install") { [weak self] in
                Task { await self?.run(.install, row) }
            }
        }
    }
    
    func didTapRemove(_ row: HarnessRow) {
        publishDialog(
            "Remove polybridge from \(row.displayName)?",
            description: "This runs polybridge-setup, which edits \(row.displayName)'s own configuration."
        ) {
            AlertAction(title: "Remove") { [weak self] in
                Task { await self?.run(.remove, row) }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func load() async {
        isLoading = true
        defer { isLoading = false }
        switch await useCase.status() {
        case .success(let document):
            rows = document.rows
            serverPath = document.serverPath
            errorMessage = nil
        case .failure(let failure):
            errorMessage = failure.message
        }
    }
    
    /// Existing issue, preserved: only the acted-on row is replaced, not a fresh status for every
    /// row (the old code's comment said otherwise; the code never did that — see `SettingsView.swift`
    /// and the settled plan's "Existing issues, not changed here" section).
    private func run(_ action: SetupClient.Action, _ row: HarnessRow) async {
        // The original's locator check ran BEFORE `working` was set (`SettingsView.swift:134`), so a
        // locator failure never entered the busy state or touched the error line at all — restored
        // here as item 8. Only a failure of the actual `perform` call below sets `errorMessage`.
        guard case .success(let setupClient) = useCase.locate() else { return }
        workingKey = row.key
        defer { workingKey = nil }
        switch await useCase.perform(action, client: row.key, using: setupClient) {
        case .success(let document):
            if let updated = document.rows.first(where: { $0.key == row.key }),
               let index = rows.firstIndex(where: { $0.key == row.key }) {
                rows[index] = updated
            }
            errorMessage = nil
        case .failure(let failure):
            errorMessage = failure.message
        }
    }
}
