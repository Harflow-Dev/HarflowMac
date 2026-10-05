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

import AppKit
import SwiftUI

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
        HStack(spacing: 3) {
            if let icon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            if viewModel.taskCountsLoading || viewModel.workflowCountsLoading { Text("…") }
            if viewModel.runningCount > 0 { Text("\(viewModel.runningCount)") }
            if viewModel.workflowActiveCount > 0 {
                Image(systemName: "arrow.triangle.branch")
                Text("\(viewModel.workflowActiveCount)")
            }
            if viewModel.workflowAttentionCount > 0 { Image(systemName: "exclamationmark.circle") }
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
#Preview("P-bridge icon") {
    MenuBarLabelView(MenuBarViewModelMock(), icon: NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil))
}

#Preview("fallback symbol") {
    MenuBarLabelView(MenuBarViewModelMock())
}
#endif
