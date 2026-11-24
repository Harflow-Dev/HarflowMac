//
//  MenuBarView.swift
//  MenuBarFeature
//
//  Redesigned popover (380x560, SPEC §6.8). Membership unchanged: roots before sub-tasks,
//  at most 3 recent groups and 6 recent roots (ordering within each group is existing, undefined
//  behaviour — not "fixed" here), opening an item selects it and opens the window, and the running
//  count covers every running task including sub-tasks. The only copy change is the zero-count
//  header title "Nothing running", which replaces the separate "Nothing running." body line.
//  No fixed background is painted: the content sits on the MenuBarExtra window's own material,
//  while the cards inside stay solid `cardFill`.
//
//  Ink on glass (user-approved amendment): text placed directly on that material uses the
//  palette's `primaryText` — section labels, the connection/loading/active-workflow subline, the
//  bare workflow read-error, and the plain recent rows — because the shared lighter inks miss
//  the 4.5:1 floor on the native glass (SPEC §§3/6.8/8 conflict resolved by user authorization).
//  Card text keeps its existing inks on the solid `cardFill` surfaces (warning capsule, red list
//  error, running/workflow row text), so no blanket style is applied above the section level.
//

import AppKit
import HfCommon
import HfUI
import MonitorCore
import SwiftUI

// MARK: - MenuBarViewModel

/// View model protocol shared by the menu bar's label (`MenuBarLabelView`) and popover content
/// (`MenuBarView`) — one instance drives both, built once by `MenuBarCoordinator`.
@MainActor
protocol MenuBarViewModel: ViewModel {
    
    var runningRows: [MenuBarRunningRowModel] { get }
    var recentGroups: [ParallelGroup] { get }
    var recentTasks: [TaskRowModel] { get }
    var isConnected: Bool { get }
    var connectionLine: String { get }
    var runningCount: Int { get }
    /// Whether work is available (runtime ready, no gate refusing work), so a new session can be started.
    var canStartNewSession: Bool { get }
    var taskCountsLoading: Bool { get }
    var workflowCountsLoading: Bool { get }
    var workflowRows: [WorkflowMenuBarRow] { get }
    var workflowActiveCount: Int { get }
    var workflowAttentionCount: Int { get }
    var workflowStatusError: String? { get }
    /// The header's subline under "N running".
    var headerSubline: String { get }
    /// The block drawn instead of the sections while the managed runtime is not ready.
    var runtimeCard: MenuBarRuntimeCard? { get }
    /// The note drawn above the sections when listing the work failed on a ready runtime.
    var refreshNote: MenuBarRefreshNote? { get }
    /// The Needs you section, or nil while loading.
    var needsYou: MenuBarNeedsYouSection? { get }
    func didDecideApproval(_ row: MenuBarNeedsYouSection.Row, decision: String)
    func didRefreshApprovals()
    /// Records the draft typed into a question card.
    func didEditAnswer(_ rowID: String, text: String)
    /// Sends the draft of a question card once. Ignored when empty, in flight, unknown or settled.
    func didSubmitAnswer(_ rowID: String)
    func didSelectNeedsYou(_ itemID: String)
    func didTapShowAllNeedsYou()

    func didAppear()
    func didDisappear()
    func didDisappearStatusItem()
    func didSelectWorkflow(_ runID: String)
    func didAppearRunningRow(_ taskID: String)
    func didDisappearRunningRow(_ taskID: String)
    func didSelectRunningTask(_ taskID: String)
    func didSelectRecentTask(_ taskID: String)
    func didSelectGroup(_ name: String)
    func didTapOpenMonitor()
    func didTapNewSession()
    func didCaptureWindowOpener(_ opener: @escaping () -> Void)
    func didTapRetryRefresh()
    /// The popover content appeared — the one reliable `MenuBarExtra` open signal. Distinct from
    /// `didAppear()`, which the always-on-screen label view also fires.
    func didPopoverOpen()
    /// The popover content disappeared.
    func didPopoverClose()
}

extension MenuBarViewModel {
    var needsYou: MenuBarNeedsYouSection? { nil }
    func didDecideApproval(_: MenuBarNeedsYouSection.Row, decision _: String) {}
    func didRefreshApprovals() {}
    func didEditAnswer(_: String, text _: String) {}
    func didSubmitAnswer(_: String) {}
    func didSelectNeedsYou(_: String) {}
    func didTapShowAllNeedsYou() {}
}

extension MenuBarViewModel {
    func didPopoverOpen() {}
    func didPopoverClose() {}
}

extension MenuBarViewModel {
    var workflowRows: [WorkflowMenuBarRow] { [] }
    var workflowActiveCount: Int { 0 }
    var workflowAttentionCount: Int { 0 }
    var workflowStatusError: String? { nil }
    func didDisappearStatusItem() {}
    func didSelectWorkflow(_: String) {}
}

extension MenuBarViewModel {
    var taskCountsLoading: Bool { false }
    var workflowCountsLoading: Bool { false }
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
        VStack(alignment: .leading, spacing: HfRadius.Metrics.zero) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing16) {
                    if let card = viewModel.runtimeCard {
                        MenuBarRuntimeCardView(card: card) { viewModel.didTapOpenMonitor() }
                    } else {
                        notices
                        needsYou
                        workflows
                        running
                        recent
                    }
                }
                .padding(HfRadius.Metrics.spacing16)
                // The document probe (§6.8): inside the popover's own document, so it can only
                // ever target this scroll view.
                .background(ScrollChrome())
            }
            Divider()
            footer
        }
        .frame(width: HfRadius.Metrics.menuBarPopoverWidth, height: HfRadius.Metrics.menuBarPopoverHeight)
        .onAppear {
            viewModel.didAppear()
            viewModel.didPopoverOpen()
        }
        .onDisappear {
            viewModel.didDisappear()
            viewModel.didPopoverClose()
        }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
    
    // MARK: - Sections
    
    private var header: some View {
        HStack(alignment: .top, spacing: HfRadius.Metrics.spacing8) {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    Text(headerTitle)
                        .font(.hf(.headline, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                    attentionCapsule
                }
                if viewModel.workflowCountsLoading {
                    // Loading text sits directly on the glass, so it takes the user-approved
                    // `primaryText` ink like the rest of the subline.
                    Text("Counting workflows…").font(.hf(.secondary)).foregroundStyle(Color.primaryText)
                }
                if viewModel.runtimeCard == nil {
                    HStack(spacing: HfRadius.Metrics.spacing5) {
                        Circle()
                            .fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed)
                            .frame(width: HfRadius.Metrics.sidebarConnectionDotSize, height: HfRadius.Metrics.sidebarConnectionDotSize)
                            .accessibilityHidden(true)
                        Text(viewModel.headerSubline).font(.hf(.secondary)).foregroundStyle(Color.primaryText).lineLimit(1)
                        if workflowActiveSuffix {
                            Text(
                                "· \(viewModel.workflowActiveCount) "
                                    + (viewModel.workflowActiveCount == 1 ? "workflow" : "workflows")
                                    + " active"
                            )
                            .font(.hf(.secondary))
                            .monospacedDigit()
                            .foregroundStyle(Color.primaryText)
                            .lineLimit(1)
                        }
                    }
                }
            }
            Spacer()
            Button { viewModel.didTapNewSession() } label: {
                Image(systemName: "plus")
                    .font(.hf(.body, weight: .semibold))
                    .foregroundStyle(viewModel.canStartNewSession ? Color.accentLink : Color.secondaryText)
                    .frame(width: HfRadius.Metrics.primaryButtonHeight, height: HfRadius.Metrics.primaryButtonHeight)
                    .background(Circle().fill(Color.cardFill))
                    .overlay(Circle().stroke(Color.hairline, lineWidth: HfRadius.Metrics.hairlineStroke))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!viewModel.canStartNewSession)
            .help(viewModel.canStartNewSession ? "New session" : "Finish setting up Harflow first")
            .accessibilityLabel("New session")
        }
        .padding(HfRadius.Metrics.spacing16)
    }

    /// The header title: today's loading text while counts load, "Nothing running" at zero, and
    /// "N running" otherwise (§6.8). The zero title replaces the removed empty-body line.
    private var headerTitle: String {
        if viewModel.taskCountsLoading { return "Counting running agents…" }
        return viewModel.runningCount == 0 ? "Nothing running" : "\(viewModel.runningCount) running"
    }

    /// The subline's active-workflow suffix shows only once the count has loaded and is positive
    /// (§6.8) — no suffix (and no count) is invented while loading.
    private var workflowActiveSuffix: Bool {
        !viewModel.workflowCountsLoading && viewModel.workflowActiveCount > 0
    }

    /// The attention capsule beside the title (§6.8): warning tint, triangle and count with
    /// grammatical agreement. Hidden while workflow counts load — the count it shows is a guess
    /// until then.
    @ViewBuilder
    private var attentionCapsule: some View {
        if !viewModel.workflowCountsLoading, viewModel.workflowAttentionCount > 0 {
            HStack(spacing: HfRadius.Metrics.spacing4) {
                StatusGlyphView(.hand, size: HfRadius.Metrics.statusBadgeGlyphFrame)
                    .accessibilityHidden(true)
                Text(
                    "\(viewModel.workflowAttentionCount) "
                        + (viewModel.workflowAttentionCount == 1 ? "needs" : "need")
                        + " attention"
                )
                .lineLimit(1)
            }
            .font(.hf(.secondary, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.warningFG)
            .padding(.horizontal, HfRadius.Metrics.spacing8)
            .padding(.vertical, HfRadius.Metrics.spacing2)
            .background(Capsule().fill(Color.warningBG))
            .accessibilityElement(children: .combine)
        }
    }
    
    @ViewBuilder
    private var notices: some View {
        if let note = viewModel.refreshNote {
            MenuBarRefreshNoteView(note: note) { viewModel.didTapRetryRefresh() }
        }
    }

    @ViewBuilder
    private var needsYou: some View {
        if let section = viewModel.needsYou {
            MenuBarNeedsYouSectionView(
                section: section, open: { viewModel.didSelectNeedsYou($0) }, showAll: { viewModel.didTapShowAllNeedsYou() },
                decide: { viewModel.didDecideApproval($0, decision: $1) }, refresh: { viewModel.didRefreshApprovals() },
                edit: { viewModel.didEditAnswer($0, text: $1) }, submit: { viewModel.didSubmitAnswer($0) }
            )
        }
    }

    /// The running rows under their new "Running" caption (§6.8) — the label exists only when rows
    /// do; the rows, leases and order are exactly what they were.
    @ViewBuilder
    private var running: some View {
        if !viewModel.runningRows.isEmpty {
            MenuBarSectionLabel(text: "Running")
            ForEach(viewModel.runningRows) { row in
                MenuBarRunningRowView(model: row) { viewModel.didSelectRunningTask(row.id) }
                    .onAppear { viewModel.didAppearRunningRow(row.id) }
                    .onDisappear { viewModel.didDisappearRunningRow(row.id) }
            }
        }
    }

    @ViewBuilder
    private var recent: some View {
        if !viewModel.recentGroups.isEmpty || !viewModel.recentTasks.isEmpty {
            MenuBarSectionLabel(text: "Recent").padding(.top, HfRadius.Metrics.spacing6)
            ForEach(viewModel.recentGroups) { group in
                MenuBarRecentRowButton { viewModel.didSelectGroup(group.name) } content: {
                    GroupRow(group: group, metadataForeground: .primaryText)
                        .foregroundStyle(Color.primaryText)
                        .contentShape(Rectangle())
                }
            }
            ForEach(viewModel.recentTasks) { task in
                MenuBarRecentRowButton { viewModel.didSelectRecentTask(task.id) } content: {
                    TaskRow(model: task, metadataForeground: .primaryText)
                        .foregroundStyle(Color.primaryText)
                        .contentShape(Rectangle())
                }
            }
        }
    }

    @ViewBuilder
    private var workflows: some View {
        let active = viewModel.workflowRows.filter(\.isActive)
        let settled = viewModel.workflowRows.filter { !$0.isActive }.prefix(3)
        if !active.isEmpty || !settled.isEmpty {
            MenuBarSectionLabel(text: "Workflows")
            ForEach(active + settled) { row in
                WorkflowMenuBarRowView(model: row) { viewModel.didSelectWorkflow(row.id) }
            }
        }
        if let error = viewModel.workflowStatusError {
            if active.isEmpty, settled.isEmpty { MenuBarSectionLabel(text: "Workflows") }
            // A bare read-error line on the glass (not on a card), so it takes the user-approved
            // `primaryText` ink like the rest of the menu's directly-mounted text.
            Text(error).font(.hf(.caption)).foregroundStyle(Color.primaryText)
        }
    }

    private var footer: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            Button { viewModel.didTapOpenMonitor() } label: {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    Text("Open Harflow")
                    Text("⌘O")
                        .font(.hf(.secondary, weight: .medium))
                        .foregroundStyle(Color.shortcutHint)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MonitorButtonStyle(.primary, height: HfRadius.Metrics.menuBarFooterButtonHeight))
            .keyboardShortcut("o")
            Menu {
                Button("Settings…") { openSettings() }
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: HfRadius.Metrics.menuBarGearIconFrame, height: HfRadius.Metrics.menuBarGearIconFrame)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: HfRadius.Metrics.menuBarFooterButtonHeight, height: HfRadius.Metrics.menuBarFooterButtonHeight)
            .background(Circle().fill(Color.cardFill))
            .overlay(Circle().stroke(Color.hairline, lineWidth: HfRadius.Metrics.hairlineStroke))
            .fixedSize()
            .accessibilityLabel("Settings and quit")
        }
        .font(.hf(.body))
        .padding(HfRadius.Metrics.spacing16)
    }
}

// MARK: - MenuBarSectionLabel

/// A menu-bar section label (§6.8): caption semibold in `primaryText`. SPEC §6.8 names
/// `tertiaryText`, but that ink misses the 4.5:1 floor on the MenuBarExtra window's native
/// glass (user-approved glass-ink amendment), so the label's ink follows the user's
/// primaryText-on-glass choice. Local to this screen because the shared `SectionLabel` renders
/// native `.secondary` for its other consumers, which must not be restyled.
struct MenuBarSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.hf(.caption, weight: .semibold))
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, HfRadius.Metrics.spacing4)
    }
}

// MARK: - MenuBarRecentRowButton

/// A recent row as a plain button with the menu-bar's local hover fill (§6.8): `selectedRow` in
/// the shared 8 pt row radius. The hover lives in this view's own presentation state. Recent rows
/// sit directly on the window's glass, so the caller passes the user-approved `primaryText`
/// metadata ink to `TaskRow`/`GroupRow` (their default rendering is unchanged for every other
/// consumer) and wraps the row content in a `primaryText` blanket — inherited only by the rows'
/// plain titles, which carry no explicit style of their own; every other row part (status icon,
/// dots, chevron, spinner, progress) styles itself explicitly and stays untouched. The blanket
/// stops at each row's content, so it never leaks into the cards above.
struct MenuBarRecentRowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .background(
                    RoundedRectangle(cornerRadius: HfRadius.row)
                        .fill(isHovered ? Color.selectedRow : Color.shadow.opacity(0))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
