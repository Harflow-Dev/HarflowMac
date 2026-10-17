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
    var taskCountsLoading: Bool { get }
    var workflowCountsLoading: Bool { get }
    var workflowRows: [WorkflowMenuBarRow] { get }
    var workflowActiveCount: Int { get }
    var workflowAttentionCount: Int { get }
    var workflowStatusError: String? { get }
    /// The header's subline under "N running".
    var headerSubline: String { get }
    /// The install/update banner, or `nil` when nothing needs surfacing — shown where the red list
    /// error shows today (settled plan, section 5).
    var installBannerModel: InstallBanner.Model? { get }

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
    func didTapInstallBannerPrimary()
    func didTapInstallBannerSecondary()
    func didTapInstallBannerDismiss()
    /// The popover content appeared — the one reliable `MenuBarExtra` open signal. Distinct from
    /// `didAppear()`, which the always-on-screen label view also fires.
    func didPopoverOpen()
    /// The popover content disappeared.
    func didPopoverClose()
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
        VStack(alignment: .leading, spacing: PbRadius.Metrics.zero) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
                    notices
                    workflows
                    running
                    recent
                }
                .padding(PbRadius.Metrics.spacing16)
                // The document probe (§6.8): inside the popover's own document, so it can only
                // ever target this scroll view.
                .background(ScrollChrome())
            }
            Divider()
            footer
        }
        .frame(width: PbRadius.Metrics.menuBarPopoverWidth, height: PbRadius.Metrics.menuBarPopoverHeight)
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
        HStack(alignment: .top, spacing: PbRadius.Metrics.spacing8) {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                HStack(spacing: PbRadius.Metrics.spacing8) {
                    Text(headerTitle)
                        .font(.pb(.headline, weight: .semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                    attentionCapsule
                }
                if viewModel.workflowCountsLoading {
                    // Loading text sits directly on the glass, so it takes the user-approved
                    // `primaryText` ink like the rest of the subline.
                    Text("Counting workflows…").font(.pb(.secondary)).foregroundStyle(Color.primaryText)
                }
                HStack(spacing: PbRadius.Metrics.spacing5) {
                    Circle()
                        .fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed)
                        .frame(width: PbRadius.Metrics.sidebarConnectionDotSize, height: PbRadius.Metrics.sidebarConnectionDotSize)
                        .accessibilityHidden(true)
                    Text(viewModel.headerSubline).font(.pb(.secondary)).foregroundStyle(Color.primaryText).lineLimit(1)
                    if workflowActiveSuffix {
                        Text(
                            "· \(viewModel.workflowActiveCount) "
                                + (viewModel.workflowActiveCount == 1 ? "workflow" : "workflows")
                                + " active"
                        )
                        .font(.pb(.secondary))
                        .monospacedDigit()
                        .foregroundStyle(Color.primaryText)
                        .lineLimit(1)
                    }
                }
            }
            Spacer()
            Button { viewModel.didTapNewSession() } label: {
                Image(systemName: "plus")
                    .font(.pb(.body, weight: .semibold))
                    .foregroundStyle(Color.accentLink)
                    .frame(width: PbRadius.Metrics.primaryButtonHeight, height: PbRadius.Metrics.primaryButtonHeight)
                    .background(Circle().fill(Color.cardFill))
                    .overlay(Circle().stroke(Color.hairline, lineWidth: PbRadius.Metrics.hairlineStroke))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New session")
            .accessibilityLabel("New session")
        }
        .padding(PbRadius.Metrics.spacing16)
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
            HStack(spacing: PbRadius.Metrics.spacing4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.pb(.caption))
                    .accessibilityHidden(true)
                Text(
                    "\(viewModel.workflowAttentionCount) "
                        + (viewModel.workflowAttentionCount == 1 ? "needs" : "need")
                        + " attention"
                )
                .lineLimit(1)
            }
            .font(.pb(.secondary, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.warningFG)
            .padding(.horizontal, PbRadius.Metrics.spacing8)
            .padding(.vertical, PbRadius.Metrics.spacing2)
            .background(Capsule().fill(Color.warningBG))
            .accessibilityElement(children: .combine)
        }
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
            ActivityCard {
                Text(listErrorMessage).font(.pb(.secondary)).foregroundStyle(Color.failedRed)
            }
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
            MenuBarSectionLabel(text: "Recent").padding(.top, PbRadius.Metrics.spacing6)
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
            // A bare read-error line on the glass (not on a card), so it takes the user-approved
            // `primaryText` ink like the rest of the menu's directly-mounted text.
            Text(error).font(.pb(.caption)).foregroundStyle(Color.primaryText)
        }
    }

    private var footer: some View {
        HStack(spacing: PbRadius.Metrics.spacing8) {
            Button { viewModel.didTapOpenMonitor() } label: {
                HStack(spacing: PbRadius.Metrics.spacing8) {
                    Text("Open Monitor")
                    Text("⌘O")
                        .font(.pb(.secondary, weight: .medium))
                        .foregroundStyle(Color.shortcutHint)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(MonitorButtonStyle(.primary, height: PbRadius.Metrics.menuBarFooterButtonHeight))
            .keyboardShortcut("o")
            Menu {
                Button("Settings…") { openSettings() }
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: PbRadius.Metrics.menuBarGearIconFrame, height: PbRadius.Metrics.menuBarGearIconFrame)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: PbRadius.Metrics.menuBarFooterButtonHeight, height: PbRadius.Metrics.menuBarFooterButtonHeight)
            .background(Circle().fill(Color.cardFill))
            .overlay(Circle().stroke(Color.hairline, lineWidth: PbRadius.Metrics.hairlineStroke))
            .fixedSize()
            .accessibilityLabel("Settings and quit")
        }
        .font(.pb(.body))
        .padding(PbRadius.Metrics.spacing16)
    }
}

// MARK: - MenuBarSectionLabel

/// A menu-bar section label (§6.8): caption semibold in `primaryText`. SPEC §6.8 names
/// `tertiaryText`, but that ink misses the 4.5:1 floor on the MenuBarExtra window's native
/// glass (user-approved glass-ink amendment), so the label's ink follows the user's
/// primaryText-on-glass choice. Local to this screen because the shared `SectionLabel` renders
/// native `.secondary` for its other consumers, which must not be restyled.
private struct MenuBarSectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.pb(.caption, weight: .semibold))
            .foregroundStyle(Color.primaryText)
            .padding(.horizontal, PbRadius.Metrics.spacing4)
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
private struct MenuBarRecentRowButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            content()
                .background(
                    RoundedRectangle(cornerRadius: PbRadius.row)
                        .fill(isHovered ? Color.selectedRow : Color.shadow.opacity(0))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#if DEBUG

// MARK: - MenuBarPreviewModel

/// Preview-only fixture covering the states the shared `MenuBarViewModelMock` cannot express
/// (workflow rows/counts, loading). Every value is explicitly dummy preview data — no production
/// counts or copy derive from it.
@MainActor
private final class MenuBarPreviewModel: MenuBarViewModel {
    var runningRows: [MenuBarRunningRowModel] = []
    var recentGroups: [ParallelGroup] = []
    var recentTasks: [TaskRowModel] = []
    var listErrorMessage: String?
    var isConnected = true
    var connectionLine = "connected · polybridge-ctl"
    var runningCount = 0
    var taskCountsLoading = false
    var workflowCountsLoading = false
    var workflowRows: [WorkflowMenuBarRow] = []
    var workflowActiveCount = 0
    var workflowAttentionCount = 0
    var workflowStatusError: String?
    var headerSubline = "polybridge connected"
    var installBannerModel: InstallBanner.Model?

    static var workflowsAndAttention: MenuBarPreviewModel {
        let model = MenuBarPreviewModel()
        model.runningRows = [
            MenuBarRunningRowModel(
                id: "p1", backend: "claude", title: "Fix the login bug", repoName: "polybridge",
                startedAt: .now.addingTimeInterval(-42), durationSeconds: nil,
                activityLine: "swift test --filter LoginTests", activityIsMonospaced: true
            )
        ]
        model.runningCount = 1
        model.workflowRows = [
            WorkflowMenuBarRow([
                "workflow_run_id": .string("w1"), "name": .string("code-review"),
                "status": .string("needs_attention"), "attention_reason": .string("Implementation reached its attempt limit.")
            ]),
            WorkflowMenuBarRow([
                "workflow_run_id": .string("w2"), "name": .string("release-checklist"), "status": .string("running")
            ])
        ].compactMap(\.self)
        model.workflowActiveCount = 2
        model.workflowAttentionCount = 1
        model.recentTasks = [
            TaskRowModel(id: "t1", backend: "codex", title: "Draft release notes", status: .completed, repoName: "polybridge", ageText: "3h")
        ]
        return model
    }

    static var loading: MenuBarPreviewModel {
        let model = MenuBarPreviewModel()
        model.taskCountsLoading = true
        model.workflowCountsLoading = true
        return model
    }

    static var listError: MenuBarPreviewModel {
        let model = MenuBarPreviewModel()
        model.listErrorMessage = "polybridge-ctl couldn't list tasks: no installation found."
        return model
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

#Preview("Menu bar workflows and attention - light") {
    MenuBarView(MenuBarPreviewModel.workflowsAndAttention).preferredColorScheme(.light)
}

#Preview("Menu bar workflows and attention - dark") {
    MenuBarView(MenuBarPreviewModel.workflowsAndAttention).preferredColorScheme(.dark)
}

#Preview("Menu bar loading - light") {
    MenuBarView(MenuBarPreviewModel.loading).preferredColorScheme(.light)
}

#Preview("Menu bar loading - dark") {
    MenuBarView(MenuBarPreviewModel.loading).preferredColorScheme(.dark)
}

#Preview("Menu bar list error - light") {
    MenuBarView(MenuBarPreviewModel.listError).preferredColorScheme(.light)
}

#Preview("Menu bar list error - dark") {
    MenuBarView(MenuBarPreviewModel.listError).preferredColorScheme(.dark)
}

#Preview("install banner - light") {
    MenuBarView(MenuBarViewModelMock.installNeeded).preferredColorScheme(.light)
}

#Preview("install banner - dark") {
    MenuBarView(MenuBarViewModelMock.installNeeded).preferredColorScheme(.dark)
}

/// The popover content as the production scene hosts it: on a native material, not a fabricated
/// flat glass colour, so the user-approved `primaryText` ink can be checked on glass in both
/// appearances. The material here is preview-only — the real MenuBarExtra window paints it.
#Preview("Menu bar on material - light") {
    MenuBarView(MenuBarViewModelMock.busy)
        .preferredColorScheme(.light)
        .background(.ultraThinMaterial)
}

#Preview("Menu bar on material - dark") {
    MenuBarView(MenuBarViewModelMock.busy)
        .preferredColorScheme(.dark)
        .background(.ultraThinMaterial)
}
#endif
