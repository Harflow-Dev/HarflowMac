//
//  HarnessesView.swift
//  SettingsFeature
//

import HfCommon
import HfUI
import MonitorCore
import SwiftUI

// MARK: - HarnessesViewModel

/// View model protocol for the Harnesses settings tab.
@MainActor
protocol HarnessesViewModel: ViewModel {
    var qualificationCards: [QualificationCard] { get }
    func didTapQualification(_ id: String)
    
    var rows: [HarnessRow] { get }
    var serverPath: String? { get }
    /// The status load's failure: the engine's sentence and, when the refusal has one, its code.
    var loadFailure: HarnessLoadFailure? { get }
    /// Failed actions by row key; a failed row shows the message, its code and Retry.
    var rowFailures: [String: HarnessRowFailure] { get }
    var isLoading: Bool { get }
    var workingKey: String? { get }
    var isRefreshDisabled: Bool { get }
    /// The runtime is not ready: the page shows a setup note instead of the list.
    var showsRuntimeSetup: Bool { get }
    /// The runtime is ready and the setup tool listed no harness.
    var showsNoHarnesses: Bool { get }

    func didAppear()
    func didDisappear()
    func didTapRefresh()
    func didTapInstall(_ row: HarnessRow)
    func didTapRemove(_ row: HarnessRow)
    func didTapRetry(_ row: HarnessRow)
    func didTapOpenSetup()
}

// MARK: - HarnessesView

/// Rows from `harflow-setup --status --json`. Install and Remove run `harflow-setup` only
/// when clicked, after a confirmation dialog.
struct HarnessesView<VM: HarnessesViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    @State private var allowlistRow: HarnessRow?
    private let buildAllowlist: (HarnessRow) -> AnyView
    
    // MARK: - Init
    
    init(_ viewModel: VM, buildAllowlist: @escaping (HarnessRow) -> AnyView = { _ in AnyView(EmptyView()) }) {
        self.buildAllowlist = buildAllowlist
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
            HStack {
                Text("Where Harflow is registered as an MCP server").font(.hf(.headline, weight: .semibold))
                Spacer()
                if viewModel.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { viewModel.didTapRefresh() }.disabled(viewModel.isRefreshDisabled)
            }
            if let serverPath = viewModel.serverPath {
                Text("Server: \(serverPath)")
                    .font(.hf(.secondary, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
            }
            if viewModel.showsRuntimeSetup {
                HarnessBlock {
                    Text("Finish runtime setup to register Harflow with your harnesses.")
                        .font(.hf(.body))
                        .foregroundStyle(Color.primaryText)
                    Button("Open setup") { viewModel.didTapOpenSetup() }
                }
                Spacer(minLength: 0)
            } else {
                registrationState
                List {
                    ForEach(viewModel.rows) { row in
                        HarnessRowView(
                            row: row,
                            isWorking: viewModel.workingKey == row.key,
                            isAnyWorking: viewModel.workingKey != nil,
                            onInstall: { viewModel.didTapInstall(row) },
                            onRemove: { viewModel.didTapRemove(row) },
                            onAllowlist: { allowlistRow = row },
                            failure: viewModel.rowFailures[row.key],
                            onRetry: { viewModel.didTapRetry(row) }
                        )
                    }
                    Section("Harness qualification") {
                        ForEach(viewModel.qualificationCards) { card in
                            HarnessQualificationCard(model: card.model) { viewModel.didTapQualification(card.id) }
                        }
                    }
                }
                // Bounded scope (§6.7): the native List's own scroll view carries thin overlay
                // chrome, independent of row presence — empty and repopulated lists keep it.
                .scrollChromeScope()
            }
        }
        .padding(HfRadius.Metrics.spacing16)
        .sheet(item: $allowlistRow) { row in
            buildAllowlist(row)
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

// MARK: - HarnessesView + Registration state

extension HarnessesView {
    /// The refused or empty block above the list; nothing while rows load or show.
    @ViewBuilder private var registrationState: some View {
        if let failure = viewModel.loadFailure {
            HarnessBlock {
                Text(failure.message)
                    .font(.hf(.body))
                    .foregroundStyle(Color.failedRed)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = failure.code { DetailLine(label: "Code", value: code) }
                Button("Retry") { viewModel.didTapRefresh() }.disabled(viewModel.isRefreshDisabled)
            }
        } else if viewModel.showsNoHarnesses {
            HarnessBlock {
                Text("No harnesses found on this Mac.")
                    .font(.hf(.body))
                    .foregroundStyle(Color.primaryText)
                Text("Install a supported harness, then refresh.")
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }
}

// MARK: - HarnessBlock

/// The design's `hd-hs-block`: a short column between two hairlines that replaces the list in a state without rows.
private struct HarnessBlock<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, HfRadius.Metrics.spacing16)
        .overlay(alignment: .top) { Rectangle().fill(Color.hairline).frame(height: 1) }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.hairline).frame(height: 1) }
    }
}

#if DEBUG
#Preview("Harnesses - light") {
    HarnessesView(HarnessesViewModelMock()).preferredColorScheme(.light)
}

#Preview("Harnesses - dark") {
    HarnessesView(HarnessesViewModelMock()).preferredColorScheme(.dark)
}

#Preview("Harnesses, runtime not ready - light") {
    HarnessesView(HarnessesViewModelMock(showsRuntimeSetup: true)).preferredColorScheme(.light)
}

#Preview("Harnesses, runtime not ready - dark") {
    HarnessesView(HarnessesViewModelMock(showsRuntimeSetup: true)).preferredColorScheme(.dark)
}

#Preview("Harnesses, setup refused - light") {
    HarnessesView(HarnessesViewModelMock(
        rows: [], serverPath: nil,
        loadFailure: .init(message: "Incompatible Harflow runtime: unsupported harflow.setup format", code: "incompatible_runtime")
    )).preferredColorScheme(.light)
}

#Preview("Harnesses, setup refused - dark") {
    HarnessesView(HarnessesViewModelMock(
        rows: [], serverPath: nil,
        loadFailure: .init(message: "Incompatible Harflow runtime: unsupported harflow.setup format", code: "incompatible_runtime")
    )).preferredColorScheme(.dark)
}

#Preview("Harnesses, none found - light") {
    HarnessesView(HarnessesViewModelMock(rows: [], serverPath: nil, showsNoHarnesses: true)).preferredColorScheme(.light)
}

#Preview("Harnesses, none found - dark") {
    HarnessesView(HarnessesViewModelMock(rows: [], serverPath: nil, showsNoHarnesses: true)).preferredColorScheme(.dark)
}

#Preview("Harnesses, registration failed - light") {
    HarnessesView(HarnessesViewModelMock(rowFailures: HarnessesViewModelMock.sampleRowFailures)).preferredColorScheme(.light)
}

#Preview("Harnesses, registration failed - dark") {
    HarnessesView(HarnessesViewModelMock(rowFailures: HarnessesViewModelMock.sampleRowFailures)).preferredColorScheme(.dark)
}
#endif

extension HarnessesViewModel {
    var qualificationCards: [QualificationCard] { [] }
    func didTapQualification(_: String) {}
}
