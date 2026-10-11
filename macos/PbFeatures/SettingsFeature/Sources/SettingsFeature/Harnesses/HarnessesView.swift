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
    /// The install/update banner, or `nil` when nothing needs surfacing — shown where the load
    /// error shows today (settled plan, section 5).
    var installBannerModel: InstallBanner.Model? { get }

    func didAppear()
    func didDisappear()
    func didTapRefresh()
    func didTapInstall(_ row: HarnessRow)
    func didTapRemove(_ row: HarnessRow)
    func didTapInstallBannerPrimary()
    func didTapInstallBannerSecondary()
    func didTapInstallBannerDismiss()
}

// MARK: - HarnessesView

/// Rows from `polybridge-setup --status --json`. Install and Remove run `polybridge-setup` only
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
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
            HStack {
                Text("Where polybridge is registered as an MCP server").font(.pb(.headline, weight: .semibold))
                Spacer()
                if viewModel.isLoading { ProgressView().controlSize(.small) }
                Button("Refresh") { viewModel.didTapRefresh() }.disabled(viewModel.isRefreshDisabled)
            }
            if let serverPath = viewModel.serverPath {
                Text("Server: \(serverPath)")
                    .font(.pb(.secondary, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
            }
            if let bannerModel = viewModel.installBannerModel {
                InstallBanner(
                    model: bannerModel,
                    onPrimary: { viewModel.didTapInstallBannerPrimary() },
                    onSecondary: { viewModel.didTapInstallBannerSecondary() },
                    onDismiss: { viewModel.didTapInstallBannerDismiss() }
                )
            } else if let errorMessage = viewModel.errorMessage {
                Text(errorMessage).font(.pb(.secondary)).foregroundStyle(Color.failedRed).textSelection(.enabled)
            }
            List(viewModel.rows) { row in
                HarnessRowView(
                    row: row,
                    isWorking: viewModel.workingKey == row.key,
                    isAnyWorking: viewModel.workingKey != nil,
                    onInstall: { viewModel.didTapInstall(row) },
                    onRemove: { viewModel.didTapRemove(row) },
                    onAllowlist: { allowlistRow = row }
                )
            }
            // Bounded scope (§6.7): the native List's own scroll view carries thin overlay
            // chrome, independent of row presence — empty and repopulated lists keep it.
            .scrollChromeScope()
        }
        .padding(PbRadius.Metrics.spacing16)
        .sheet(item: $allowlistRow) { row in
            buildAllowlist(row)
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
#Preview("Harnesses - light") {
    HarnessesView(HarnessesViewModelMock()).preferredColorScheme(.light)
}

#Preview("Harnesses - dark") {
    HarnessesView(HarnessesViewModelMock()).preferredColorScheme(.dark)
}

#Preview("Harnesses, install banner - light") {
    HarnessesView(HarnessesViewModelMock(installBannerModel: .init(
        title: "polybridge isn't installed",
        detail: "polybridge-ctl wasn't found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.",
        primaryTitle: "Install polybridge"
    ))).preferredColorScheme(.light)
}

#Preview("Harnesses, install banner - dark") {
    HarnessesView(HarnessesViewModelMock(installBannerModel: .init(
        title: "polybridge isn't installed",
        detail: "polybridge-ctl wasn't found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.",
        primaryTitle: "Install polybridge"
    ))).preferredColorScheme(.dark)
}

/// The dummy load-failure state: the red error line where the banner otherwise shows.
#Preview("Harnesses, load error - light") {
    HarnessesView(HarnessesViewModelMock(errorMessage: "polybridge-setup failed: not found on PATH."))
        .preferredColorScheme(.light)
}

#Preview("Harnesses, load error - dark") {
    HarnessesView(HarnessesViewModelMock(errorMessage: "polybridge-setup failed: not found on PATH."))
        .preferredColorScheme(.dark)
}
#endif
