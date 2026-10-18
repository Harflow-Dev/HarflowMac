//
//  MenuBarLabelView.swift
//  MenuBarFeature
//
//  Ported from the app target's `MenuBarView.swift` (`MenuBarLabel`). The status item is always on
//  screen, so this is where the window opener is captured — independent of whether the popover
//  (`MenuBarView`) has ever been opened. It shares the same `MenuBarVM` instance as the popover
//  content (built once by `MenuBarCoordinator`), which is why `runningCount` stays accurate even
//  while the popover is closed — see `MenuBarVM`'s header comment on that judgement call.
//
//  Decision 8: `icon` is the app target's "P-bridge" menu-bar template image, loaded once by
//  `loadMenuBarIcon(from:)` and passed down as a plain value (no repository, no VM change — a
//  trivial component may take plain values, per the root AGENTS.md's Component Models section).
//  `nil` falls back to the SF Symbol this view always drew before.
//
//  Native-host override (the user's explicit choice, after a real MenuBarExtra.window capture):
//  the status item draws the template icon (or its SF Symbol fallback), the loading ellipsis while
//  counts load, and the running count when positive — nothing else. The workflow-active branch and
//  the attention triangle were removed as visuals (MenuBarExtra flattens extra children anyway);
//  their counts survive in the aggregate `accessibilityValue` below and in the popover's content.
//

import AppKit
import MonitorCore
import PbUI
import SwiftUI

// MARK: - MenuBarLabelView

struct MenuBarLabelView<VM: MenuBarViewModel>: View {

    // MARK: - Environment

    @Environment(\.openWindow) private var openWindow

    // MARK: - State

    @State var viewModel: VM

    // MARK: - Properties

    let icon: NSImage?

    // MARK: - Init

    init(_ viewModel: VM, icon: NSImage? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.icon = icon
    }

    // MARK: - View Body

    var body: some View {
        HStack(spacing: PbRadius.Metrics.menuBarItemSpacing) {
            if let icon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            if viewModel.taskCountsLoading || viewModel.workflowCountsLoading { Text("…") }
            if viewModel.runningCount > 0 { Text("\(viewModel.runningCount)").monospacedDigit() }
        }
        .accessibilityLabel("Polybridge Monitor")
        .accessibilityValue(
            (viewModel.taskCountsLoading ? "Agent count loading, " : "\(viewModel.runningCount) agents running, ")
                + (viewModel.workflowCountsLoading ? "Workflow count loading, " : "\(viewModel.workflowActiveCount) workflows, ")
                + (viewModel.workflowCountsLoading ? "Attention count loading" : "\(viewModel.workflowAttentionCount) need attention")
        )
        .onAppear {
            viewModel.didAppear()
            viewModel.didCaptureWindowOpener { openWindow(id: "main") }
        }
        .onDisappear { viewModel.didDisappearStatusItem() }
    }
}

#if DEBUG

// MARK: - MenuBarLabelPreviewModel

/// Preview-only fixture for the label's states the shared `MenuBarViewModelMock` cannot express
/// (workflow counts, loading). Every value is explicitly dummy preview data.
@MainActor
private final class MenuBarLabelPreviewModel: MenuBarViewModel {
    var runningRows: [MenuBarRunningRowModel] = []
    var recentGroups: [ParallelGroup] = []
    var recentTasks: [TaskRowModel] = []
    var listErrorMessage: String?
    var isConnected = true
    var connectionLine = "connected · polybridge-ctl"
    var runningCount: Int
    var taskCountsLoading: Bool
    var workflowCountsLoading: Bool
    var workflowActiveCount: Int
    var workflowAttentionCount: Int
    var workflowRows: [WorkflowMenuBarRow] = []
    var workflowStatusError: String?
    var headerSubline = "polybridge connected"
    var installBannerModel: InstallBanner.Model?

    init(
        runningCount: Int = 0,
        taskCountsLoading: Bool = false,
        workflowCountsLoading: Bool = false,
        workflowActiveCount: Int = 0,
        workflowAttentionCount: Int = 0
    ) {
        self.runningCount = runningCount
        self.taskCountsLoading = taskCountsLoading
        self.workflowCountsLoading = workflowCountsLoading
        self.workflowActiveCount = workflowActiveCount
        self.workflowAttentionCount = workflowAttentionCount
    }

    func didAppear() {}
    func didDisappear() {}
    func didAppearRunningRow(_: String) {}
    func didDisappearRunningRow(_: String) {}
    func didSelectRunningTask(_: String) {}
    func didSelectRecentTask(_: String) {}
    func didSelectGroup(_: String) {}
    func didTapOpenMonitor() {}
    func didTapNewSession() {}
    func didCaptureWindowOpener(_: @escaping () -> Void) {}
    func didTapInstallBannerPrimary() {}
    func didTapInstallBannerSecondary() {}
    func didTapInstallBannerDismiss() {}
}

#Preview("P-bridge icon - light") {
    MenuBarLabelView(MenuBarViewModelMock(), icon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil))
        .preferredColorScheme(.light)
}

#Preview("P-bridge icon - dark") {
    MenuBarLabelView(MenuBarViewModelMock(), icon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil))
        .preferredColorScheme(.dark)
}

#Preview("Label idle - light") {
    MenuBarLabelView(MenuBarLabelPreviewModel()).preferredColorScheme(.light)
}

#Preview("Label idle - dark") {
    MenuBarLabelView(MenuBarLabelPreviewModel()).preferredColorScheme(.dark)
}

#Preview("Label running - light") {
    MenuBarLabelView(MenuBarLabelPreviewModel(runningCount: 2)).preferredColorScheme(.light)
}

#Preview("Label running - dark") {
    MenuBarLabelView(MenuBarLabelPreviewModel(runningCount: 2)).preferredColorScheme(.dark)
}

#Preview("Label workflow and attention counts (AX value only) - light") {
    MenuBarLabelView(
        MenuBarLabelPreviewModel(runningCount: 2, workflowActiveCount: 1, workflowAttentionCount: 1)
    )
    .preferredColorScheme(.light)
}

#Preview("Label workflow and attention counts (AX value only) - dark") {
    MenuBarLabelView(
        MenuBarLabelPreviewModel(runningCount: 2, workflowActiveCount: 1, workflowAttentionCount: 1)
    )
    .preferredColorScheme(.dark)
}

#Preview("Label loading - light") {
    MenuBarLabelView(MenuBarLabelPreviewModel(taskCountsLoading: true, workflowCountsLoading: true))
        .preferredColorScheme(.light)
}

#Preview("Label loading - dark") {
    MenuBarLabelView(MenuBarLabelPreviewModel(taskCountsLoading: true, workflowCountsLoading: true))
        .preferredColorScheme(.dark)
}
#endif
