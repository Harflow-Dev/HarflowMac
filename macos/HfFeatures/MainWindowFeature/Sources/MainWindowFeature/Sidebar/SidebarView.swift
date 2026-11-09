//
//  SidebarView.swift
//  MainWindowFeature
//
//  The redesigned sidebar (Monitor redesign Phase 1, SPEC §6.1): a fixed New session button (the
//  old toolbar "+" action) above the search field and the compact backend-dot filter, the Running /
//  Today / Earlier list (whole trees and parallel groups, settled plan D10), history diagnostics
//  with a manual Load older control while more pages exist. Search is
//  trimmed, lowercased and case-insensitive over title/ID/repo; the backend filter composes with
//  lineage retention. `SettingsLink` stays.
//

import HfCommon
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - SidebarViewModel

/// View model protocol for the Sidebar screen.
@MainActor
protocol SidebarViewModel: ViewModel {
    
    /// Running / Today / Earlier, in that order, empty buckets omitted (settled plan D10).
    var storeNeedsAttention: Bool { get }
    var runtimeSetupState: RuntimeSetupState { get }
    func didTapRuntimeSetup()
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
    /// 4): true only before the first listing arrives (`hasListed == false`) with no list error —
    /// see `SidebarVM.recompute()`.
    var showsLoadingSkeleton: Bool { get }
    var isConnected: Bool { get }
    var appAppearance: AppAppearance { get }
    var connectionLine: String { get }
    var backendTabs: [BackendTab] { get }
    var selectedBackend: String { get }
    var catalogUnavailableNote: String? { get }
    var searchQuery: String { get }
    var selection: MonitorDestination? { get }
    /// The Needs you row's badge.
    var needsYouBadge: NeedsYouBadge { get }
    var savedWorkflows: [WorkflowRecord] { get }
    var workflowErrorMessage: String? { get }
    func didTapNewWorkflow()
    func groupConversations(_ group: ParallelGroup) -> [Conversation]
    func isExecutionParentExpanded(_ id: String) -> Bool

    func didAppear()
    func didSelectAppearance(_ appearance: AppAppearance)
    func didDisappear()
    func didChangeSearchQuery(_ text: String)
    func didSelectBackendFilter(_ backend: String)
    func didSelect(_ destination: MonitorDestination?)
    func didTapNewSession()

    // MARK: Collapsible tree (settled plan, Monitor piece 4)

    func didToggleExpansion(taskID: String)
    /// ← collapses the selected row (or moves to its parent); → expands it — see `SidebarVM`.
    func didPressMoveCommand(_ direction: MoveCommandDirection)
}

extension SidebarViewModel {
    var needsYouBadge: NeedsYouBadge { .none }
    var storeNeedsAttention: Bool { false }
    var runtimeSetupState: RuntimeSetupState { .ready }
    func didTapRuntimeSetup() {}
    var appAppearance: AppAppearance { .system }
    func didSelectAppearance(_: AppAppearance) {}
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
    @Environment(\.toggleHarflowSidebar) private var toggleSidebar
    
    // MARK: - State
    
    @State var viewModel: VM
    private let managesLifecycle: Bool
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride
    @Environment(\.defaultMinListRowHeight) private var minimumRowHeight
    @State private var seenRowIDs: Set<String> = []
    @State private var displayedSections: [SidebarSection]?
    @State private var fadingRowIDs: Set<String> = []
    @State private var disclosureTask: Task<Void, Never>?
    @State private var transitionRelay = SidebarNativeTransitionRelay()
    @State private var transitionEpoch = 0

    /// The setup gate line: 13 pt on a 1.5 line height.
    private static var setupGateText: TaskScreenStyle.TextSpec { .init(size: 13, lineHeight: 19.5) }

    private var reduceMotion: Bool {
        HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }
    
    // MARK: - Init
    
    init(_ viewModel: VM, managesLifecycle: Bool = true) {
        _viewModel = State(initialValue: viewModel)
        self.managesLifecycle = managesLifecycle
    }
    
    // MARK: - View Body
    
    var body: some View {
        Group {
            if viewModel.runtimeSetupState.isReady {
                VStack(spacing: 0) {
                    header
                    list
                    footer
                }
            } else {
                // Setup gate: title row, one line of text, then the shared footer. Actions live in
                // the main pane and Settings.
                VStack(spacing: HfRadius.Metrics.zero) {
                    header
                    Text("Runtime setup required before creating or loading work.")
                        .font(TaskScreenStyle.sans(size: Self.setupGateText.size))
                        .lineSpacing(TaskScreenStyle.lineSpacing(Self.setupGateText))
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityIdentifier("sidebar-setup-gate")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, HfRadius.Metrics.spacing8)
                        .padding(.bottom, HfRadius.Metrics.spacing24)
                        .padding(.horizontal, HfRadius.Metrics.spacing16)
                    Spacer(minLength: HfRadius.Metrics.zero)
                    footer
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .accessibilityIdentifier("main-window-sidebar")
        .onAppear { if managesLifecycle { viewModel.didAppear() } }
        .onDisappear { if managesLifecycle { viewModel.didDisappear() } }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    // MARK: - Private Views

    /// Fixed title row. Store attention and the catalog note follow it in the ready layout only.
    private var header: some View {
        VStack(spacing: HfRadius.Metrics.spacing8) {
            HStack {
                Text("Harflow").font(.headline)
                Spacer()
                Button(action: { toggleSidebar?() }) { SidebarNavigationIcon(.sidebar, size: 16) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Collapse sidebar")
            }
            .padding(.bottom, 8)
            if viewModel.runtimeSetupState.isReady {
                if viewModel.storeNeedsAttention {
                    SettingsLink {
                        Label("Task store needs attention", systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .help("Open Settings → General to inspect the store and review recovery")
                    .accessibilityIdentifier("sidebar-store-attention")
                }
                if let note = viewModel.catalogUnavailableNote {
                    Text(note)
                        .font(.hf(.caption))
                        .foregroundStyle(Color.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, HfRadius.Metrics.spacing16)
        .padding(.top, HfRadius.Metrics.spacing12)
        .padding(.bottom, HfRadius.Metrics.spacing8)
    }

    /// M04 `.hd-m04-sidebar-scroll`: navigation, Running and Recent work scroll as one bounded
    /// native outline under the fixed header and above the fixed footer.
    private var list: some View {
        nativeList
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("sidebar-unified")
            .onChange(of: viewModel.sections) { old, new in reconcileRows(from: old, to: new) }
            .onDisappear {
                disclosureTask?.cancel()
                displayedSections = nil
                fadingRowIDs = []
            }
    }

    private var nativeList: some View {
        SidebarNativeList(
            presentation: SidebarListPresentation(
                sections: displayedSections ?? viewModel.sections,
                workflowTitles: viewModel.savedWorkflows.map(\.id),
                workflowsExpanded: false,
                listError: viewModel.listErrorMessage,
                skeleton: viewModel.showsLoadingSkeleton,
                taskHistory: viewModel.taskHistoryState,
                workflowHistory: viewModel.workflowHistoryState,
                emptyMessage: viewModel.emptyStateMessage,
                fadingIDs: fadingRowIDs,
                minimumRowHeight: minimumRowHeight,
                historyRevision: viewModel.historyPresentationRevision,
                historyToken: historyLayoutToken,
                transitionEpoch: transitionEpoch,
                needsYouBadge: viewModel.needsYouBadge,
                role: .unified
            ),
            selection: viewModel.selection,
            seenIDs: seenRowIDs,
            configureActions: { actions in
                actions.select = { destination in
                    // New task stays a composer request gated on runtime readiness, never a
                    // destination selection; every other destination routes through didSelect.
                    if destination == .newSession {
                        viewModel.didTapNewSession()
                    } else {
                        viewModel.didSelect(destination)
                    }
                }
                actions.toggle = toggleExpansion
                actions.newWorkflow = viewModel.didTapNewWorkflow
                actions.loadTasks = viewModel.didTapLoadMoreTasks
                actions.loadWorkflows = viewModel.didTapLoadMoreWorkflows
                actions.move = { direction in
                    withAnimation(HfMotion.disclosure(reduceMotion: reduceMotion)) { viewModel.didPressMoveCommand(direction) }
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
        .environment(\.defaultMinListRowHeight, 0)
        .animation(HfMotion.disclosure(reduceMotion: reduceMotion), value: expansionToken)
        .hfFadeIn()
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
            withAnimation(HfMotion.disclosure(reduceMotion: reduceMotion)) {
                transitionEpoch += 1
                transitionRelay.end(removed, epoch: transitionEpoch)
                displayedSections = new
            }
        }
    }

    private func toggleExpansion(_ id: String) {
        withAnimation(HfMotion.disclosure(reduceMotion: reduceMotion)) { viewModel.didToggleExpansion(taskID: id) }
    }

    private var footer: some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            Divider()
            WorkflowErrorsEntryView()
                .padding(.horizontal, HfRadius.Metrics.spacing16)
            HStack(spacing: HfRadius.Metrics.spacing6) {
                SidebarAppearanceControl(appearance: viewModel.appAppearance, onSelect: viewModel.didSelectAppearance)
                Spacer(minLength: HfRadius.Metrics.zero)
                SettingsLink { SidebarNavigationIcon(.settings, size: 16) }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, HfRadius.Metrics.spacing16)
            .padding(.top, HfRadius.Metrics.spacing8)
            .padding(.bottom, HfRadius.Metrics.spacing12)
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
            .font(.hf(.caption, weight: .semibold))
            .foregroundStyle(Color.tertiaryText)
    }
}

#if DEBUG
#Preview("Sidebar section heading - light") {
    SidebarSectionHeading(text: "Running").padding(HfRadius.Metrics.spacing8).preferredColorScheme(.light)
}

#Preview("Sidebar section heading - dark") {
    SidebarSectionHeading(text: "Running").padding(HfRadius.Metrics.spacing8).preferredColorScheme(.dark)
}
#endif
