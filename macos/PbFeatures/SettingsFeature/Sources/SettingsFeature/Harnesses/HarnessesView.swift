//
//  HarnessesView.swift
//  SettingsFeature
//

import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - HarnessesViewModel

/// View model protocol for the Harnesses settings tab.
@MainActor
protocol HarnessesViewModel: ViewModel {
    
    var rows: [HarnessRow] { get }
    var serverPath: String? { get }
    var errorMessage: String? { get }
    var isLoading: Bool { get }
    var workingKey: String? { get }
    var isRefreshDisabled: Bool { get }
    
    func didAppear()
    func didDisappear()
    func didTapRefresh()
    func didTapInstall(_ row: HarnessRow)
    func didTapRemove(_ row: HarnessRow)
}

// MARK: - HarnessesView

/// Rows from `polybridge-setup --status --json`. Install and Remove run `polybridge-setup` only
/// when clicked, after a confirmation dialog.
struct HarnessesView<VM: HarnessesViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Where polybridge is registered as an MCP server").font(.system(size: 13, weight: .semibold))
                Spacer()
                if viewModel.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { viewModel.didTapRefresh() }.disabled(viewModel.isRefreshDisabled)
            }
            if let serverPath = viewModel.serverPath {
                Text("Server: \(serverPath)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).font(.system(size: 11)).foregroundStyle(Color.failedRed).textSelection(.enabled)
            }
            List(viewModel.rows) { row in
                HarnessRowView(
                    row: row,
                    isWorking: viewModel.workingKey == row.key,
                    isAnyWorking: viewModel.workingKey != nil,
                    onInstall: { viewModel.didTapInstall(row) },
                    onRemove: { viewModel.didTapRemove(row) }
                )
            }
        }
        .padding(16)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
#Preview {
    HarnessesView(HarnessesViewModelMock())
}
#endif
