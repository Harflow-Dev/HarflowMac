//
//  MenuBarView.swift
//  MenuBarFeature
//
//  Ported from the app target's `MenuBarView.swift`. Behaviour unchanged: roots before sub-tasks,
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
    var openWindowOnStart: Bool { get }
    var notifyOnFinish: Bool { get }
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
    func didToggleOpenWindowOnStart(_ isOn: Bool)
    func didToggleNotifyOnFinish(_ isOn: Bool)
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
    
    // MARK: - State
    
    @State var viewModel: VM
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Polybridge — \(viewModel.runningCount) running").font(.pb(.headline, weight: .semibold)).padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
                    ForEach(viewModel.runningRows) { row in
                        MenuBarRunningRowView(model: row) { viewModel.didSelectRunningTask(row.id) }
                            .onAppear { viewModel.didAppearRunningRow(row.id) }
                            .onDisappear { viewModel.didDisappearRunningRow(row.id) }
                    }
                    if viewModel.runningRows.isEmpty, viewModel.listErrorMessage == nil, viewModel.installBannerModel == nil {
                        Text("Nothing running.").font(.pb(.body)).foregroundStyle(.secondary)
                    }
                    if !viewModel.recentGroups.isEmpty || !viewModel.recentTasks.isEmpty {
                        SectionLabel(text: "Recent").padding(.top, 6)
                        ForEach(viewModel.recentGroups) { group in
                            Button { viewModel.didSelectGroup(group.name) } label: {
                                HStack { GroupRow(group: group) }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        ForEach(viewModel.recentTasks) { task in
                            Button { viewModel.didSelectRecentTask(task.id) } label: {
                                TaskRow(model: task).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button("Open Monitor") { viewModel.didTapOpenMonitor() }.keyboardShortcut("o")
                Toggle(
                    "Open window when a task starts",
                    isOn: Binding(get: { viewModel.openWindowOnStart }, set: { viewModel.didToggleOpenWindowOnStart($0) })
                )
                Toggle(
                    "Notify when a task finishes",
                    isOn: Binding(get: { viewModel.notifyOnFinish }, set: { viewModel.didToggleNotifyOnFinish($0) })
                )
            }
            .font(.pb(.body))
            .padding(12)
            Divider()
            HStack {
                Circle().fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed).frame(width: 7, height: 7)
                Text(viewModel.connectionLine).font(.pb(.secondary)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.pb(.secondary))
            }
            .padding(12)
        }
        .frame(width: 380, height: 580)
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
#Preview {
    MenuBarView(MenuBarViewModelMock())
}

#Preview("install banner") {
    MenuBarView(MenuBarViewModelMock(installBannerModel: .init(
        title: "polybridge isn't installed",
        detail: "polybridge-ctl wasn't found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.",
        primaryTitle: "Install polybridge"
    )))
}
#endif
