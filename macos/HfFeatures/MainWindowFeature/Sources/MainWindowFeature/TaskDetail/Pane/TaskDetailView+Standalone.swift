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

    /// Durable operation feedback occupies space only while the VM supplies a message.
    @ViewBuilder var standaloneOutcomeFeedback: some View {
        if let message = viewModel.outcomeMessage {
            Text(message)
                .font(.hf(.secondary))
                .foregroundStyle(OutcomeColor.of(message))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, HfRadius.Metrics.spacing24)
                .padding(.vertical, HfRadius.Metrics.spacing8)
                .readingColumn()
        }
    }

    /// Approved M05 provenance line; the VM owns the first conversation member's provenance.
    @ViewBuilder var standaloneProvenanceLine: some View {
        if isStandalone, viewModel.spawnedByBannerText != nil {
            HStack(spacing: HfRadius.Metrics.spacing6) {
                Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
                Text("Sub-task started by another agent")
            }
            .font(TaskScreenStyle.sans(size: 12))
            .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TaskScreenStyle.Transcript.paddingHorizontal)
            .padding(.bottom, HfRadius.Metrics.spacing16)
            .readingColumn()
        }
    }

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
        let selectedTab = pane.selectedTab
        let reserved = isOpen && mode == .split ? TaskScreenStyle.PaneHead.width : HfRadius.Metrics.zero
        return columnStack(task)
            .padding(.trailing, reserved)
            // The reserved band lies outside the column's own background, so paint it too: a slide never shows the window.
            .background(transcriptStyle.isTranscript ? TaskScreenStyle.Colors.pageBackground.color : Color.windowBG)
            .overlay(alignment: .trailing) {
                if isOpen, let mode { paneView(mode, selectedTab: selectedTab) }
            }
            .background(PaneEscapeMonitor(isActive: isOpen,
                                          toolbarOriginIdentifier: pane.revealOrigin.flatMap(TaskPaneChipFocus.toolbarIdentifier(for:)),
                                          handle: { handleEscape() }))
            .background(TaskPaneFocusAnchor(host: paneHolder.chipFocus))
            .onChange(of: viewModel.snapshotEvidence?.paneDefault ?? .init(), initial: true) { _, input in pane.updateDefaultInput(input) }
            .onChange(of: pane.isOpen, initial: true) { _, open in viewModel.setPaneOpen(open) }
            .onChange(of: reduceMotion, initial: true) { _, reduced in pane.reducesMotion = reduced }
            .onChange(of: pane.focusReturn) { _, origin in returnFocus(to: origin) }
            .onChange(of: viewModel.changesSelection) { _, selection in pane.recordChangesSelection(selection) }
            .onAppear {
                pane.touch()
                viewModel.restoreChangesSelection(pane.changesSelection)
                viewModel.setPaneOpen(pane.isOpen)
                pane.focusProbe = { [chipFocus = paneHolder.chipFocus] in chipFocus.probe() }
            }
            .onDisappear {
                paneHolder.chipFocus.cancel()
                pane.focusProbe = nil
            }
            .opensFileLinks(repoPath: task.repoPath)
    }

    func paneView(_ mode: TaskPaneController.Mode, selectedTab: TaskPaneStateStore.Tab) -> some View {
        TaskPaneView(viewModel: viewModel, pane: pane, presentation: mode, selectedTab: selectedTab,
                     focus: TaskPaneFocus(group: $focusedGroup, accessibilityGroup: $groupAccessibilityFocus))
            .transition(.move(edge: .trailing))
    }

    /// Moves focus, and the VoiceOver cursor, back to the control a reveal started from, then drops the request.
    /// The assignment waits a turn so the group header or closing pane has released focus first; set in the same
    /// transaction, SwiftUI can drop the new focus when the old one resigns.
    ///
    /// A header origin sits in this hosting view and keeps the plain deferred assignment. A chip origin lives in the window
    /// toolbar: ALL of its assignments (the SwiftUI keyboard and accessibility bindings and the native first-responder move)
    /// run inside one mounted request, under the same current-request, originating-window, key-window, sheet and user-input
    /// checks, and none runs after the view disappears. A close that did not probe focus (no mounted window) returns nothing.
    func returnFocus(to origin: TaskPaneController.Origin?, probed: PaneFocusSnapshot? = nil) {
        guard let origin else { return }
        let generation = pane.returnGeneration
        let wasOpen = pane.isOpen
        // A close hands over the snapshot it took. Leaving a focused facts group keeps the pane open and takes none, so its
        // caller passes the focus it read before clearing the group.
        let snapshot = pane.takeReturnSnapshot() ?? probed
        pane.consumeFocusReturn()
        if let identifier = TaskPaneChipFocus.toolbarIdentifier(for: origin) {
            guard snapshot != nil else { return }
            paneHolder.chipFocus.start(
                identifier: identifier, snapshot: snapshot,
                isCurrent: { [pane] in
                    wasOpen ? pane.returnGeneration == generation && pane.isOpen : pane.isCurrentReturn(generation: generation)
                },
                applyBindings: {
                    originFocus = origin
                    originAccessibilityFocus = origin
                }
            )
            return
        }
        Task { @MainActor [pane] in
            await Task.yield()
            // A later pane change (a reopen, a new reveal, a tab choice) makes this return stale.
            guard pane.returnGeneration == generation else { return }
            originFocus = origin
            originAccessibilityFocus = origin
        }
    }

    /// Escape: leave a focused facts group, else close an overlay, else close a pane a reveal opened. A closing
    /// Escape returns focus through the controller's focus return, exactly like the close button and the toolbar toggle.
    /// Returns whether the key was used, so the monitor consumes only an Escape that dismissed something.
    func handleEscape() -> Bool {
        let probed = paneHolder.chipFocus.probe()
        let groupFocused = focusedGroup != nil || groupAccessibilityFocus != nil ||
            (pane.revealOrigin != nil && pane.selectedTab == .events && probed.axFocusOnFactsHeader)
        let outcome = pane.animated { pane.handleEscape(groupFocused: groupFocused) }
        if case .leftFactsGroup(let origin) = outcome {
            // Use the snapshot from before the group gave up focus.
            focusedGroup = nil
            groupAccessibilityFocus = nil
            returnFocus(to: origin, probed: probed)
        }
        return outcome != .ignored
    }

    /// Opens the legacy inspector from the Group or embedded header.
    func revealNotices() {
        setInspectorVisible(true)
    }

    func revealContinuityDetails() {
        setInspectorVisible(true)
        snapshotFactsExpanded = true
        supervisionRequest += 1
    }

    /// The standalone toolbar's chips; `nil` on the other mounts.
    func toolbarChips(_ task: TaskInfo) -> TaskTopBarChips? {
        guard isStandalone else { return nil }
        return TaskTopBarChips.make(task: task, model: viewModel.inspectorModel, isNarrow: topBarIsNarrow)
    }

    /// The top bar chips: each opens the pane on its facts group and returns focus to the chip when it closes.
    func revealContinuityChip() { pane.animated { pane.revealFacts(group: .continuity, origin: .chipContinuity) } }
    func revealNoticesChip() { pane.animated { pane.revealFacts(group: .notices, origin: .chipNotices) } }
    func revealAccessChip() { pane.animated { pane.revealFacts(group: .enforcement, origin: .chipAccess) } }

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

// MARK: - NoticeSummary

/// The header's one-line pointer to the inspector's Notices section.
enum NoticeSummary {
    static func text(count: Int) -> String? {
        count > 0 ? "\(count) notice\(count == 1 ? "" : "s")" : nil
    }
}

// MARK: - StandaloneFocusable

/// Makes a control programmatically focusable on the standalone mount only. Elsewhere it is the identity, so the
/// group and embedded mounts keep the controls' default focus behaviour exactly.
struct StandaloneFocusable: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled { content.focusable() } else { content }
    }
}
