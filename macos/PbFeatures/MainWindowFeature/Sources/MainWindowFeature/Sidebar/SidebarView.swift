//
//  SidebarView.swift
//  MainWindowFeature
//
//  The redesigned sidebar (Monitor redesign Phase 1, SPEC §6.1): a fixed New session button (the
//  old toolbar "+" action) above the search field and the compact backend-dot filter, the Running /
//  Today / Earlier list (whole trees and parallel groups, settled plan D10), history diagnostics
//  with a manual Load older control while more pages exist, and a connection footer. Search is
//  trimmed, lowercased and case-insensitive over title/ID/repo; the backend filter composes with
//  lineage retention. `SettingsLink` stays.
//

import MonitorCore
import PbCommon
import PbRepository
import PbUI
import SwiftUI

// MARK: - SidebarViewModel

/// View model protocol for the Sidebar screen.
@MainActor
protocol SidebarViewModel: ViewModel {
    
    /// Running / Today / Earlier, in that order, empty buckets omitted (settled plan D10).
    var sections: [SidebarSection] { get }
    var taskHistoryState: HistoryLoadingState { get }
    var workflowHistoryState: HistoryLoadingState { get }
    var historyPresentationRevision: Int { get }
    func didChangeHistoryBottomVisibility(_ visible: Bool, revision: Int)
    func didTapLoadMoreTasks()
    func didTapLoadMoreWorkflows()
    var listErrorMessage: String? { get }
    /// The list body's empty-state message, or `nil` when there's real content to show (Monitor
    /// piece 6's precedence rules — see `SidebarVM.computeEmptyStateMessage()`).
    var emptyStateMessage: String? { get }
    /// A shimmer placeholder instead of an empty list (Monitor piece 11, Plan review round 1 item
    /// 4): true only before the first listing arrives (`hasListed == false`) with no error and no
    /// install banner already occupying the space — see `SidebarVM.recompute()`.
    var showsLoadingSkeleton: Bool { get }
    var isConnected: Bool { get }
    var connectionLine: String { get }
    var backendTabs: [BackendTab] { get }
    var selectedBackend: String { get }
    var catalogUnavailableNote: String? { get }
    var searchQuery: String { get }
    var selection: MonitorDestination? { get }
    /// The install/update banner, or `nil` when nothing needs surfacing — shown in place of the
    /// red error section (settled plan, section 5).
    var installBannerModel: InstallBanner.Model? { get }
    var savedWorkflows: [WorkflowRecord] { get }
    var workflowErrorMessage: String? { get }
    func didTapNewWorkflow()
    func groupConversations(_ group: ParallelGroup) -> [Conversation]
    func isExecutionParentExpanded(_ id: String) -> Bool

    func didAppear()
    func didDisappear()
    func didChangeSearchQuery(_ text: String)
    func didSelectBackendFilter(_ backend: String)
    func didSelect(_ destination: MonitorDestination?)
    func didTapNewSession()
    func didTapInstallBannerPrimary()
    func didTapInstallBannerSecondary()
    func didTapInstallBannerDismiss()

    // MARK: Collapsible tree (settled plan, Monitor piece 4)

    func didToggleExpansion(taskID: String)
    /// ← collapses the selected row (or moves to its parent); → expands it — see `SidebarVM`.
    func didPressMoveCommand(_ direction: MoveCommandDirection)
}

extension SidebarViewModel {
    var savedWorkflows: [WorkflowRecord] { [] }
    var workflowErrorMessage: String? { nil }
    func didTapNewWorkflow() {}
    func groupConversations(_ group: ParallelGroup) -> [Conversation] { group.conversations }
    func isExecutionParentExpanded(_ id: String) -> Bool { false }
}

extension SidebarViewModel {
    var taskHistoryState: HistoryLoadingState { HistoryLoadingState() }
    var workflowHistoryState: HistoryLoadingState { HistoryLoadingState() }
    var historyPresentationRevision: Int { 0 }
    func didChangeHistoryBottomVisibility(_: Bool, revision _: Int) {}
    func didTapLoadMoreTasks() {}
    func didTapLoadMoreWorkflows() {}
}

// MARK: - SidebarView

struct SidebarView<VM: SidebarViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pbReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.defaultMinListRowHeight) private var minimumRowHeight
    @State private var seenRowIDs: Set<String> = []
    @State private var displayedSections: [SidebarSection]?
    @State private var fadingRowIDs: Set<String> = []
    @State private var disclosureTask: Task<Void, Never>?
    @State private var transitionRelay = SidebarNativeTransitionRelay()
    @State private var transitionEpoch = 0
    @State private var workflowsExpanded = true

    private var reduceMotion: Bool {
        PbMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        list
            // Let the native sidebar List own the titlebar safe area. A surrounding VStack
            // can be extended underneath the unified toolbar when leaving full screen.
            .safeAreaInset(edge: .top, spacing: PbRadius.Metrics.zero) {
                header.background(.bar)
            }
            .safeAreaInset(edge: .bottom, spacing: PbRadius.Metrics.zero) { footer.background(.bar) }
        // New session moved from the toolbar into the column itself (SPEC §6.1): the same
        // `didTapNewSession` action, now a fixed full-width button above the search field — never
        // a scrollable List row. The window controls and the sidebar toggle stay system-owned.
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    // MARK: - Private Views

    /// The fixed controls above the list: the full-width New session button, then the search field
    /// beside the compact backend-dot filter, then the degraded-catalog note when there is one.
    private var header: some View {
        VStack(spacing: PbRadius.Metrics.spacing8) {
            newSessionButton
            ViewThatFits(in: .horizontal) {
                HStack(spacing: PbRadius.Metrics.spacing6) {
                    searchField.frame(minWidth: PbRadius.Metrics.sidebarSearchMinimumWidth)
                    backendFilterMenu.fixedSize()
                }
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
                    searchField
                    backendFilterMenu
                }
            }
            if let note = viewModel.catalogUnavailableNote {
                Text(note)
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, PbRadius.Metrics.spacing16)
        .padding(.top, PbRadius.Metrics.spacing12)
        .padding(.bottom, PbRadius.Metrics.spacing8)
    }

    /// The sidebar's New session control: the existing action today's toolbar "+" performs, with the
    /// app-owned ⌘N shortcut shown as a display-only hint — no new `keyboardShortcut` is attached
    /// here, because the shortcut already belongs to the app's command handling. VoiceOver hears
    /// the plain "New session" label; the hint is hidden from it.
    private var newSessionButton: some View {
        Button(action: { viewModel.didTapNewSession() }) {
            HStack(spacing: PbRadius.Metrics.spacing8) {
                Image(systemName: "plus")
                    .font(.pb(.body, weight: .semibold))
                    .foregroundStyle(Color.accentLink)
                Text("New session")
                Spacer(minLength: PbRadius.Metrics.spacing4)
                Text("⌘N")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.tertiaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(MonitorButtonStyle(.glass))
        .help("New session")
        .accessibilityLabel("New session")
    }

    private var searchField: some View {
        HStack(spacing: PbRadius.Metrics.spacing6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Color.secondaryText)
            TextField("Search loaded history", text: Binding(get: { viewModel.searchQuery }, set: { viewModel.didChangeSearchQuery($0) }))
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, PbRadius.Metrics.spacing10)
        .padding(.vertical, PbRadius.Metrics.spacing6)
        .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.pillFill))
    }

    /// The backend filter as a compact control beside the search field: one dot per catalog entry
    /// besides "all" (unknown and history-only backends included), the selected name, and a
    /// chevron. The menu's choices, not-found titles, accessibility value and the degraded-catalog
    /// note are exactly today's.
    private var backendFilterMenu: some View {
        Menu {
            ForEach(viewModel.backendTabs) { tab in
                Button {
                    viewModel.didSelectBackendFilter(tab.id)
                } label: {
                    if tab.id == viewModel.selectedBackend {
                        Label(menuTitle(for: tab), systemImage: "checkmark")
                    } else {
                        Text(menuTitle(for: tab))
                    }
                }
            }
        } label: {
            SidebarBackendFilterLabel(
                backendIDs: viewModel.backendTabs.filter { $0.id != "all" }.map(\.id),
                selectedTitle: viewModel.selectedBackend == "all" ? nil : selectedTitle
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("Backend filter")
        .accessibilityValue(selectedTitle)
    }

    private var selectedTitle: String {
        viewModel.selectedBackend == "all" ? "All agents" : BackendStyle.displayName(viewModel.selectedBackend)
    }

    private func menuTitle(for tab: BackendTab) -> String {
        if tab.id == "all" { return "All agents" }
        let name = BackendStyle.displayName(tab.id)
        return tab.isNotFound ? "\(name) (not found on PATH)" : name
    }

    private var list: some View {
        SidebarNativeList(
            presentation: SidebarListPresentation(
                sections: displayedSections ?? viewModel.sections,
                workflowTitles: viewModel.savedWorkflows.map(\.id),
                workflowsExpanded: workflowsExpanded,
                banner: viewModel.installBannerModel.map(SidebarBannerPresentation.init),
                listError: viewModel.listErrorMessage,
                skeleton: viewModel.showsLoadingSkeleton,
                taskHistory: viewModel.taskHistoryState,
                workflowHistory: viewModel.workflowHistoryState,
                emptyMessage: viewModel.emptyStateMessage,
                fadingIDs: fadingRowIDs,
                minimumRowHeight: minimumRowHeight,
                historyRevision: viewModel.historyPresentationRevision,
                historyToken: historyLayoutToken,
                transitionEpoch: transitionEpoch
            ),
            selection: viewModel.selection,
            seenIDs: seenRowIDs,
            configureActions: { actions in
                actions.select = viewModel.didSelect
                actions.toggle = toggleExpansion
                actions.toggleWorkflows = {
                    withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) { workflowsExpanded.toggle() }
                }
                actions.newWorkflow = viewModel.didTapNewWorkflow
                actions.primary = viewModel.didTapInstallBannerPrimary
                actions.secondary = viewModel.didTapInstallBannerSecondary
                actions.dismiss = viewModel.didTapInstallBannerDismiss
                actions.loadTasks = viewModel.didTapLoadMoreTasks
                actions.loadWorkflows = viewModel.didTapLoadMoreWorkflows
                actions.move = { direction in
                    withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) { viewModel.didPressMoveCommand(direction) }
                }
                actions.mounted = { ids in
                    let new = ids.subtracting(seenRowIDs)
                    if !new.isEmpty { seenRowIDs.formUnion(new) }
                }
                actions.history = { visible, revision in
                    viewModel.didChangeHistoryBottomVisibility(visible, revision: revision)
                }
            },
            relay: transitionRelay
        )
        .scrollChromeScope()
        .padding(.top, PbRadius.Metrics.spacing8)
        .environment(\.defaultMinListRowHeight, 0)
        .animation(PbMotion.disclosure(reduceMotion: reduceMotion), value: expansionToken)
        .pbFadeIn()
        .onChange(of: viewModel.sections) { old, new in reconcileRows(from: old, to: new) }
        .onDisappear {
            disclosureTask?.cancel()
            displayedSections = nil
            fadingRowIDs = []
        }
    }

    /// A content change requests a fresh layout even when the trailing frame is unchanged.
    private var historyLayoutToken: String {
        let sections = displayedSections ?? viewModel.sections
        let rowCount = sections.reduce(0) { $0 + $1.items.count }
        let lastRow = sections.last?.items.last?.id ?? ""
        let taskCursor = viewModel.taskHistoryState.nextCursor ?? ""
        let workflowCursor = viewModel.workflowHistoryState.nextCursor ?? ""
        return "\(rowCount):\(lastRow):\(taskCursor):\(workflowCursor)"
            + ":\(viewModel.taskHistoryState.isLoading):\(viewModel.workflowHistoryState.isLoading)"
    }

    private var expansionToken: [String] {
        viewModel.sections.flatMap(\.items).compactMap { item in
            switch item {
            case .task(let row), .workflow(let row), .workflowShortcut(let row, _):
                row.hasChildren ? "\(item.id):\(row.isExpanded)" : nil
            case .group(let group):
                "\(item.id):\(group.isExpanded)"
            }
        }
    }

    private func reconcileRows(from old: [SidebarSection], to new: [SidebarSection]) {
        disclosureTask?.cancel()
        let newIDs = Set(new.flatMap(\.items).map(\.id))
        let current = displayedSections ?? old
        let removed = Set(current.flatMap(\.items).map(\.id)).subtracting(newIDs)
        let restored = fadingRowIDs.intersection(newIDs)
        let newlyFading = removed.subtracting(fadingRowIDs)
        seenRowIDs.formIntersection(newIDs)
        // List retains outgoing cells during its deletion animation. Keep their closed
        // presentation until that identity is explicitly reintroduced by a new snapshot.
        fadingRowIDs.formUnion(removed)
        fadingRowIDs.subtract(newIDs)
        displayedSections = SidebarSection.retainingRemovedRows(from: current, in: new)
        if !newlyFading.isEmpty || !restored.isEmpty {
            transitionEpoch += 1
            transitionRelay.publish(fading: newlyFading, restored: restored, epoch: transitionEpoch)
        }
        guard !removed.isEmpty else { return }
        // Native List removal is immediate. Keep outgoing cells while their disclosure closes,
        // then remove them; a newer snapshot cancels this pending removal.
        disclosureTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(reduceMotion ? 180 : 200)) } catch { return }
            withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) {
                transitionEpoch += 1
                transitionRelay.end(removed, epoch: transitionEpoch)
                displayedSections = new
            }
        }
    }

    private func toggleExpansion(_ id: String) {
        withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) { viewModel.didToggleExpansion(taskID: id) }
    }

    private var footer: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
            Divider()
            HStack(spacing: PbRadius.Metrics.spacing6) {
                Circle()
                    .fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed)
                    .frame(width: PbRadius.Metrics.sidebarConnectionDotSize, height: PbRadius.Metrics.sidebarConnectionDotSize)
                Text(viewModel.isConnected ? "Connected" : "Disconnected")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .help(viewModel.listErrorMessage ?? viewModel.connectionLine)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, PbRadius.Metrics.spacing16)
            .padding(.vertical, PbRadius.Metrics.spacing12)
        }
    }
}

// MARK: - SidebarSectionHeading

/// The sidebar's own section heading (§6.1): caption-semibold `tertiaryText`, sentence case. Local
/// on purpose — the shared `SectionLabel` keeps its many later-phase consumers untouched.
private struct SidebarSectionHeading: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.pb(.caption, weight: .semibold))
            .foregroundStyle(Color.tertiaryText)
    }
}

#if DEBUG
#Preview("Sidebar section heading - light") {
    SidebarSectionHeading(text: "Running").padding(PbRadius.Metrics.spacing8).preferredColorScheme(.light)
}

#Preview("Sidebar section heading - dark") {
    SidebarSectionHeading(text: "Running").padding(PbRadius.Metrics.spacing8).preferredColorScheme(.dark)
}
#endif
