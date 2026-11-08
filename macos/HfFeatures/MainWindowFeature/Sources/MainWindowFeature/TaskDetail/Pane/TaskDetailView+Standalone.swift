//
//  TaskDetailView+Standalone.swift
//  MainWindowFeature
//
//  The standalone mount of `TaskDetailView`: the adaptive right pane beside or over the transcript column, its
//  first-show default, the reveal routes from the header and the Escape order. The group and embedded mounts keep
//  the legacy layout in `TaskDetailView.swift`.
//

import HfUI
import MonitorCore
import SwiftUI

// MARK: - Standalone mount

extension TaskDetailView {

    /// The standalone mount. The measuring view is a flexible clear layer that the column and pane are drawn over,
    /// never inside, so the width it reports cannot depend on whether the pane is split, overlaid or closed.
    func standaloneLayout(_ task: TaskInfo) -> some View {
        Color.clear
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { pane.updateContainerWidth($0) }
            .overlay { standaloneBody(task) }
    }

    /// The column is the one stable view; the pane is drawn over its trailing edge in both modes, and in split mode
    /// the column reserves the pane's width. Crossing the threshold therefore changes padding and elevation only
    /// and never remounts the pane or its state.
    func standaloneBody(_ task: TaskInfo) -> some View {
        let isOpen = pane.isOpen
        let mode = pane.mode
        let reserved = isOpen && mode == .split ? TaskScreenStyle.PaneHead.width : HfRadius.Metrics.zero
        return columnStack(task)
            .padding(.trailing, reserved)
            // The reserved band lies outside the column's own background, so paint it too: a slide never shows the window.
            .background(transcriptStyle.isTranscript ? TaskScreenStyle.Colors.pageBackground.color : Color.windowBG)
            .overlay(alignment: .trailing) {
                if isOpen, let mode { paneView(mode) }
            }
            .background(PaneEscapeMonitor(isActive: isOpen, handle: handleEscape))
            .onChange(of: viewModel.snapshotEvidence?.paneDefault ?? .init(), initial: true) { _, input in pane.updateDefaultInput(input) }
            .onChange(of: reduceMotion, initial: true) { _, reduced in pane.reducesMotion = reduced }
            .onChange(of: pane.focusReturn) { _, origin in returnFocus(to: origin) }
            .onAppear { pane.touch() }
            .opensFileLinks(repoPath: task.repoPath)
    }

    func paneView(_ mode: TaskPaneController.Mode) -> some View {
        TaskPaneView(viewModel: viewModel, pane: pane, presentation: mode,
                     focus: TaskPaneFocus(group: $focusedGroup, accessibilityGroup: $groupAccessibilityFocus))
            .transition(.move(edge: .trailing))
    }

    /// Moves focus, and the VoiceOver cursor, back to the header control a reveal started from, then drops the request.
    /// The assignment waits one turn so the group header or closing pane has released focus first; set in the same
    /// transaction, SwiftUI can drop the new focus when the old one resigns.
    func returnFocus(to origin: TaskPaneController.Origin?) {
        guard let origin else { return }
        pane.consumeFocusReturn()
        Task { @MainActor in
            await Task.yield()
            originFocus = origin
            originAccessibilityFocus = origin
        }
    }

    /// Escape: leave a focused facts group, else close an overlay, else close a pane a reveal opened. A closing
    /// Escape returns focus through the controller's focus return, exactly like the close button and the toolbar toggle.
    /// Returns whether the key was used, so the monitor consumes only an Escape that dismissed something.
    func handleEscape() -> Bool {
        let outcome = pane.animated { pane.handleEscape(groupFocused: focusedGroup != nil) }
        if case .leftFactsGroup(let origin) = outcome {
            focusedGroup = nil
            groupAccessibilityFocus = nil
            returnFocus(to: origin)
        }
        return outcome != .ignored
    }

    /// Opens the standalone pane on a facts group, or the legacy inspector for the other mounts.
    func revealNotices() {
        if isStandalone {
            pane.animated { pane.revealFacts(group: .notices, origin: .notices) }
        } else {
            setInspectorVisible(true)
        }
    }

    func revealContinuityDetails() {
        if isStandalone {
            pane.animated { pane.revealFacts(group: .continuity, origin: .continuityDetails) }
        } else {
            setInspectorVisible(true)
            snapshotFactsExpanded = true
            supervisionRequest += 1
        }
    }

    /// The overflow menu's "Events" item: opens the pane, or the legacy inspector, on the events.
    func showEvents() {
        if isStandalone {
            pane.animated { pane.select(.events) }
        } else {
            eventsExpanded = true
        }
    }

    /// The toolbar's pane toggle.
    func toggleInspector() {
        if isStandalone {
            pane.animated { pane.toggle() }
        } else {
            eventsExpanded.toggle()
        }
    }
}
