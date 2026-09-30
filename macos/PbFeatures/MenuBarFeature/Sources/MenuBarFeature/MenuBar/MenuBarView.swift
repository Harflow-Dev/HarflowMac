//
//  MenuBarView.swift
//  MenuBarFeature
//
//  Redesigned popover (380x560). Membership unchanged: roots before sub-tasks,
//  at most 3 recent groups and 6 recent roots (ordering within each group is existing, undefined
//  behaviour — not "fixed" here), opening an item selects it and opens the window, and the running
//  count covers every running task including sub-tasks.
//

import AppKit
import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - MenuBarViewModel

/// View model protocol shared by the menu bar's label (`MenuBarLabelView`) and popover content
/// (`MenuBarView`) — one instance drives both, built once by `MenuBarCoordinator`.
@MainActor
protocol MenuBarViewModel: ViewModel {
    
    var runningRows: [MenuBarRunningRowModel] { get }
    var recentGroups: [ParallelGroup] { get }
    var recentTasks: [TaskRowModel] { get }
    var listErrorMessage: String? { get }
    var isConnected: Bool { get }
    var connectionLine: String { get }
    var runningCount: Int { get }
    /// The header's subline under "N running".
    var headerSubline: String { get }
    /// The install/update banner, or `nil` when nothing needs surfacing — shown where the red list
    /// error shows today (settled plan, section 5).
    var installBannerModel: InstallBanner.Model? { get }

    func didAppear()
    func didDisappear()
    func didAppearRunningRow(_ taskID: String)
    func didDisappearRunningRow(_ taskID: String)
    func didSelectRunningTask(_ taskID: String)
    func didSelectRecentTask(_ taskID: String)
    func didSelectGroup(_ name: String)
    func didTapOpenMonitor()
    func didTapNewSession()
    func didCaptureWindowOpener(_ opener: @escaping () -> Void)
    func didTapInstallBannerPrimary()
    func didTapInstallBannerSecondary()
    func didTapInstallBannerDismiss()
}

// MARK: - MenuBarView

/// The status item's popover content.
struct MenuBarView<VM: MenuBarViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    @Environment(\.openSettings) private var openSettings
    
    // MARK: - State
    
    @State var viewModel: VM
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    notices
                    ForEach(viewModel.runningRows) { row in
                        MenuBarRunningRowView(model: row) { viewModel.didSelectRunningTask(row.id) }
                            .onAppear { viewModel.didAppearRunningRow(row.id) }
                            .onDisappear { viewModel.didDisappearRunningRow(row.id) }
                    }
                    if viewModel.runningRows.isEmpty, viewModel.listErrorMessage == nil, viewModel.installBannerModel == nil {
                        Text("Nothing running.").font(.pb(.body)).foregroundStyle(Color.secondaryText)
                    }
                    recent
                }
                .padding(12)
            }
            Divider()
            footer
        }
        .frame(width: 380, height: 560)
        .background(Color.windowBG)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
    
    // MARK: - Sections
    
    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(viewModel.runningCount) running").font(.pb(.headline, weight: .semibold))
                HStack(spacing: 5) {
                    Circle().fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed).frame(width: 7, height: 7)
                    Text(viewModel.headerSubline).font(.pb(.caption)).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            }
            Spacer()
            Button { viewModel.didTapNewSession() } label: {
                Image(systemName: "plus").font(.pb(.body, weight: .semibold)).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New session")
            .accessibilityLabel("New session")
        }
        .padding(12)
    }
    
    @ViewBuilder
    private var notices: some View {
        if let bannerModel = viewModel.installBannerModel {
            InstallBanner(
                model: bannerModel,
                onPrimary: { viewModel.didTapInstallBannerPrimary() },
                onSecondary: { viewModel.didTapInstallBannerSecondary() },
                onDismiss: { viewModel.didTapInstallBannerDismiss() }
            )
        } else if let listErrorMessage = viewModel.listErrorMessage {
            Text(listErrorMessage).font(.pb(.secondary)).foregroundStyle(Color.failedRed)
        }
    }
    
    @ViewBuilder
    private var recent: some View {
        if !viewModel.recentGroups.isEmpty || !viewModel.recentTasks.isEmpty {
            SectionLabel(text: "Recent").padding(.top, 6)
            ForEach(viewModel.recentGroups) { group in
                Button { viewModel.didSelectGroup(group.name) } label: {
                    GroupRow(group: group).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            ForEach(viewModel.recentTasks) { task in
                Button { viewModel.didSelectRecentTask(task.id) } label: {
                    TaskRow(model: task).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }
    
    private var footer: some View {
        HStack(spacing: 8) {
            Button { viewModel.didTapOpenMonitor() } label: {
                Text("Open Monitor").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o")
            Menu {
                Button("Settings…") { openSettings() }
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Settings and quit")
        }
        .font(.pb(.body))
        .padding(12)
    }
}

#if DEBUG
#Preview("Menu bar - light") {
    MenuBarView(MenuBarViewModelMock.busy).preferredColorScheme(.light)
}

#Preview("Menu bar - dark") {
    MenuBarView(MenuBarViewModelMock.busy).preferredColorScheme(.dark)
}

#Preview("Menu bar empty - light") {
    MenuBarView(MenuBarViewModelMock(runningRows: [], recentTasks: [], runningCount: 0)).preferredColorScheme(.light)
}

#Preview("Menu bar empty - dark") {
    MenuBarView(MenuBarViewModelMock(runningRows: [], recentTasks: [], runningCount: 0)).preferredColorScheme(.dark)
}

#Preview("install banner - light") {
    MenuBarView(MenuBarViewModelMock.installNeeded).preferredColorScheme(.light)
}

#Preview("install banner - dark") {
    MenuBarView(MenuBarViewModelMock.installNeeded).preferredColorScheme(.dark)
}
#endif
