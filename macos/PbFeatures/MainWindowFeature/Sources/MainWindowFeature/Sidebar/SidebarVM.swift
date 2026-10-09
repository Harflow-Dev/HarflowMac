import AppKit
import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import PbUtilities
import SwiftUI

// MARK: - SidebarVM

/// View model for the Sidebar screen: search/backend filtering, sections, and the interactive
/// sessions list, ported from the old `SidebarView.swift` with no behaviour change.
@Observable
@MainActor
final class SidebarVM: SidebarViewModel {
    @ObservationIgnored var workflowDefinitions: [WorkflowRecord] = []
    @ObservationIgnored private var renderedSavedWorkflows: [WorkflowRecord] = []
    var savedWorkflows: [WorkflowRecord] {
        get { access(keyPath: \.savedWorkflows); return renderedSavedWorkflows }
        set {
            guard renderedSavedWorkflows != newValue else { return }
            withMutation(keyPath: \.savedWorkflows) { renderedSavedWorkflows = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored private var renderedHistoryPresentationRevision = 0
    private(set) var historyPresentationRevision: Int {
        get { access(keyPath: \.historyPresentationRevision); return renderedHistoryPresentationRevision }
        set {
            guard renderedHistoryPresentationRevision != newValue else { return }
            withMutation(keyPath: \.historyPresentationRevision) { renderedHistoryPresentationRevision = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored var historyViewportRevision = -1
    @ObservationIgnored var historyBottomVisible = false
    @ObservationIgnored var taskHistoryLoadTask: Task<Void, Never>?
    @ObservationIgnored var workflowHistoryLoadTask: Task<Void, Never>?
    @ObservationIgnored var taskHistoryRequestedCursor: String?
    @ObservationIgnored var workflowHistoryRequestedCursor: String?
    @ObservationIgnored var presentationBuild: @Sendable (SidebarPresentationInput) async -> SidebarPresentationBuild? = {
        SidebarPresentationBuilder.compute($0)
    }

    @ObservationIgnored var presentationWorker: Task<SidebarPresentationBuild?, Never>?
    @ObservationIgnored var presentationCompletion: Task<Void, Never>?
    @ObservationIgnored var activePresentationInput: SidebarPresentationInput?
    @ObservationIgnored var pendingPresentationInput: SidebarPresentationInput?
    @ObservationIgnored var pendingPresentationStart: UInt64?
    @ObservationIgnored var pendingPresentationScheduledStart: UInt64?
    @ObservationIgnored var desiredSelection: MonitorDestination?
    @ObservationIgnored var presentationRevision = 0
    @ObservationIgnored var presentationEpoch = 0
    @ObservationIgnored var presentationEnabled = true
    @ObservationIgnored var indexedWorkflowOwners: [String: String] = [:]
    @ObservationIgnored var indexedWorkflowChildren: [String: [TaskInfo]] = [:]
    @ObservationIgnored var indexedGroupConversations: [String: [Conversation]] = [:]
    @ObservationIgnored var indexedRepresentatives: [String: String] = [:]
    @ObservationIgnored var indexedExecutionParents: [String: String] = [:]
    @ObservationIgnored var latestTitles: [String: String] = [:]
    @ObservationIgnored var nextPresentationTransaction = Transaction()
    @ObservationIgnored var presentationWrites = 0
    @ObservationIgnored var invocationDetails: (String) -> [String: JSONValue]? = { _ in nil }
    @ObservationIgnored var childInvocationRefreshOffset = 0
    @ObservationIgnored var workflowRuns: [SidebarWorkflowRun] = []
    @ObservationIgnored private var renderedWorkflowErrorMessage: String?
    var workflowErrorMessage: String? {
        get { access(keyPath: \.workflowErrorMessage); return renderedWorkflowErrorMessage }
        set {
            guard renderedWorkflowErrorMessage != newValue else { return }
            withMutation(keyPath: \.workflowErrorMessage) { renderedWorkflowErrorMessage = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored var workflowPoll: Task<Void, Never>?
    @ObservationIgnored var workflowGeneration = UUID()
    @ObservationIgnored let historyUseCase: (any SidebarHistoryUseCase)?
    @ObservationIgnored let workflowUseCase: (any SidebarWorkflowUseCase)?
    
    // MARK: - SidebarViewModel Properties
    
    /// Running / Today / Earlier, each holding whole root trees and parallel groups (settled plan D10).
    @ObservationIgnored private var renderedSections: [SidebarSection] = []
    private(set) var sections: [SidebarSection] {
        get { access(keyPath: \.sections); return renderedSections }
        set {
            guard renderedSections != newValue else { return }
            withMutation(keyPath: \.sections) { renderedSections = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored private var renderedListErrorMessage: String?
    var listErrorMessage: String? {
        get { access(keyPath: \.listErrorMessage); return renderedListErrorMessage }
        set {
            guard renderedListErrorMessage != newValue else { return }
            withMutation(keyPath: \.listErrorMessage) { renderedListErrorMessage = newValue }
            presentationWrites += 1
        }
    }

    /// The precedence-ordered empty-state message for the list body, or `nil` when real content (or
    /// a connection/error/banner state that already owns the space) makes one unnecessary — see
    /// `computeEmptyStateMessage()` for the exact rule (Monitor piece 6, Review round 1 item 3).
    /// Written from `SidebarVM+InstallBanner.swift`'s `recomputeInstallBanner()` too (Code review
    /// round 1, finding 4 — the message depends on `installBannerModel`, so a banner change must
    /// recompute it), so it cannot be `private(set)` — `private` is file-scoped in Swift, same
    /// reasoning as `installBannerModel` just below.
    @ObservationIgnored private var renderedEmptyStateMessage: String?
    var emptyStateMessage: String? {
        get { access(keyPath: \.emptyStateMessage); return renderedEmptyStateMessage }
        set {
            guard renderedEmptyStateMessage != newValue else { return }
            withMutation(keyPath: \.emptyStateMessage) { renderedEmptyStateMessage = newValue }
            presentationWrites += 1
        }
    }

    /// A shimmer placeholder instead of an empty list (Plan review round 1 item 4) — true only
    /// before the first listing arrives, with no error and no install banner already occupying the
    /// space (see `computeShowsLoadingSkeleton()`). Starts `true`: before ANY publisher has fired at
    /// all (the gap between `didAppear()` and the first `recompute()`), the list is otherwise blank
    /// with no message at all — exactly the stall this shimmer replaces.
    ///
    /// Not `private(set)`: `SidebarVM+InstallBanner.swift`'s `recomputeInstallBanner()` writes this
    /// too (Codex review round 1, finding 3) — a banner appearing or clearing before the first
    /// listing arrives must recompute it there too, same reasoning as `emptyStateMessage` above.
    /// `private` is file-scoped in Swift.
    @ObservationIgnored private var renderedShowsLoadingSkeleton: Bool = true
    var showsLoadingSkeleton: Bool {
        get { access(keyPath: \.showsLoadingSkeleton); return renderedShowsLoadingSkeleton }
        set {
            guard renderedShowsLoadingSkeleton != newValue else { return }
            withMutation(keyPath: \.showsLoadingSkeleton) { renderedShowsLoadingSkeleton = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored private var renderedIsConnected: Bool = false
    private(set) var isConnected: Bool {
        get { access(keyPath: \.isConnected); return renderedIsConnected }
        set {
            guard renderedIsConnected != newValue else { return }
            withMutation(keyPath: \.isConnected) { renderedIsConnected = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored private var renderedConnectionLine: String
    private(set) var connectionLine: String {
        get { access(keyPath: \.connectionLine); return renderedConnectionLine }
        set {
            guard renderedConnectionLine != newValue else { return }
            withMutation(keyPath: \.connectionLine) { renderedConnectionLine = newValue }
            presentationWrites += 1
        }
    }

    /// "All" plus every backend polybridge reports (registry order), plus any backend seen only in
    /// task history (alphabetical) — Design point 3/Review round 1 item 5.
    /// Written from `SidebarVM+Backends.swift` too, hence not `private(set)` (`private` is file-scoped).
    @ObservationIgnored private var renderedBackendTabs: [BackendTab] = [.all]
    var backendTabs: [BackendTab] {
        get { access(keyPath: \.backendTabs); return renderedBackendTabs }
        set {
            guard renderedBackendTabs != newValue else { return }
            withMutation(keyPath: \.backendTabs) { renderedBackendTabs = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored private var renderedTaskHistoryState: HistoryLoadingState = .init()
    var taskHistoryState: HistoryLoadingState {
        get { access(keyPath: \.taskHistoryState); return renderedTaskHistoryState }
        set {
            guard renderedTaskHistoryState != newValue else { return }
            withMutation(keyPath: \.taskHistoryState) { renderedTaskHistoryState = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored private var renderedWorkflowHistoryState: HistoryLoadingState = .init()
    var workflowHistoryState: HistoryLoadingState {
        get { access(keyPath: \.workflowHistoryState); return renderedWorkflowHistoryState }
        set {
            guard renderedWorkflowHistoryState != newValue else { return }
            withMutation(keyPath: \.workflowHistoryState) { renderedWorkflowHistoryState = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored var workflowHistoryInitialized = false
    @ObservationIgnored var workflowRefreshOffset = 0

    @ObservationIgnored private var renderedSelectedBackend: String = "all"
    var selectedBackend: String {
        get { access(keyPath: \.selectedBackend); return renderedSelectedBackend }
        set {
            guard renderedSelectedBackend != newValue else { return }
            withMutation(keyPath: \.selectedBackend) { renderedSelectedBackend = newValue }
            presentationWrites += 1
        }
    }

    /// A quiet note shown near the tab row when the catalog is degraded with nothing carried over —
    /// "Backend list unavailable — update polybridge." (Review round 1 item 2). `nil` otherwise.
    @ObservationIgnored private var renderedCatalogUnavailableNote: String?
    var catalogUnavailableNote: String? {
        get { access(keyPath: \.catalogUnavailableNote); return renderedCatalogUnavailableNote }
        set {
            guard renderedCatalogUnavailableNote != newValue else { return }
            withMutation(keyPath: \.catalogUnavailableNote) { renderedCatalogUnavailableNote = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored private var renderedSearchQuery: String = ""
    private(set) var searchQuery: String {
        get { access(keyPath: \.searchQuery); return renderedSearchQuery }
        set {
            guard renderedSearchQuery != newValue else { return }
            withMutation(keyPath: \.searchQuery) { renderedSearchQuery = newValue }
            presentationWrites += 1
        }
    }

    /// Normalized highlight is published separately from requested navigation.
    @ObservationIgnored var pendingWorkflowRevealID: String?
    @ObservationIgnored private var renderedSelection: MonitorDestination?
    private(set) var selection: MonitorDestination? {
        get { access(keyPath: \.selection); return renderedSelection }
        set {
            guard renderedSelection != newValue else { return }
            withMutation(keyPath: \.selection) { renderedSelection = newValue }
            presentationWrites += 1
        }
    }

    @ObservationIgnored var selectionRevision = 0
    /// The install/update banner to show in place of the red error section, or `nil` when nothing
    /// needs surfacing (settled plan, section 5's precedence rules). Written from
    /// `SidebarVM+InstallBanner.swift` too, so it cannot be `private(set)` — `private` is
    /// file-scoped in Swift (same reasoning as `TaskDetailVM`'s own cross-file-written properties).
    /// It stays non-public regardless: no external module can write it.
    @ObservationIgnored private var renderedInstallBannerModel: InstallBanner.Model?
    var installBannerModel: InstallBanner.Model? {
        get { access(keyPath: \.installBannerModel); return renderedInstallBannerModel }
        set {
            guard renderedInstallBannerModel != newValue else { return }
            withMutation(keyPath: \.installBannerModel) { renderedInstallBannerModel = newValue }
            presentationWrites += 1
        }
    }

    // MARK: - Private Properties

    // The properties below are read or written from `SidebarVM+InstallBanner.swift` as well as this
    // file, so — same reasoning as `installBannerModel` above — they cannot be `private`.
    @ObservationIgnored let useCase: any SidebarUseCase
    @ObservationIgnored let routing: any SidebarRouting
    @ObservationIgnored var cancellables = Set<AnyCancellable>()
    @ObservationIgnored var didSubscribe = false
    // `latestTasks`/`collapsedTaskIDs`/`lastKnownSiblingsByMember` are also read/written from
    // `SidebarVM+Retention.swift` (Review round 1, item 4's "retention while open"), so — same
    // reasoning as the install-banner properties above — they cannot be `private`.
    @ObservationIgnored var latestTasks: [TaskInfo] = []
    /// Indexes from the last applied presentation; all construction runs in the worker.
    @ObservationIgnored var conversationIndex = ConversationIndex([])
    @ObservationIgnored var latestListError: ToolError?
    @ObservationIgnored var latestHasListed = false
    @ObservationIgnored var latestCatalog: BackendCatalog
    /// The clock Today/Earlier bucketing reads; tests replace it.
    @ObservationIgnored var currentDate: () -> Date = { Date() }
    @ObservationIgnored var installState: InstallState = .idle
    @ObservationIgnored var lastCheckMessage: String?
    @ObservationIgnored var installAnywayBlockedMessage: String?
    @ObservationIgnored var currentInstallNeed: InstallNeed?
    /// Tasks the person has collapsed in the sidebar's tree — expanded by default (Design point 3).
    /// Lives for the app's lifetime (this VM is cached across window close/reopen); never mutated by
    /// an ordinary `recompute()` — only `didToggleExpansion(taskID:)` and an applied reveal touch it.
    @ObservationIgnored var collapsedTaskIDs: Set<String> = []
    @ObservationIgnored var expandedExecutionParents: Set<String> = []
    /// A reveal that could not be applied yet because its task was not in `latestTasks` — retried on
    /// every `tasksPublisher` emission until it lands, or replaced by a fresher one.
    @ObservationIgnored var pendingRevealToApply: PendingReveal?
    /// Every member id ever seen, mapped to its whole conversation's member set as of the last time
    /// that conversation was resolvable directly (Review round 1, item 4 — "retention while open").
    /// Never cleared; only overwritten per member on each recompute. Read when an id is no longer in
    /// `latestTasks` at all (its own record was pruned) to find a still-present sibling and resolve
    /// — and carry collapse state — through the conversation it now identifies.
    @ObservationIgnored var lastKnownSiblingsByMember: [String: Set<String>] = [:]

    // MARK: - Init

    init(useCase: any SidebarUseCase, routing: any SidebarRouting, workflowUseCase: (any SidebarWorkflowUseCase)? = nil,
         historyUseCase: (any SidebarHistoryUseCase)? = nil) {
        self.workflowUseCase = workflowUseCase
        self.historyUseCase = historyUseCase ?? (useCase as? any SidebarHistoryUseCase)
        self.useCase = useCase
        self.routing = routing
        self.renderedConnectionLine = useCase.connectionLine
        let initialSelection = routing.selection
        self.renderedSelection = initialSelection
        self.desiredSelection = initialSelection
        self.installState = useCase.installState
        self.lastCheckMessage = useCase.lastCheckMessage
        self.installAnywayBlockedMessage = useCase.installAnywayBlockedMessage
        self.latestCatalog = useCase.backendCatalog
        recomputeInstallBanner()
        recomputeBackendTabs()
    }

    // MARK: - SidebarViewModel Methods

    func didAppear() {
        presentationEnabled = true
        // Re-sync unconditionally, even if already subscribed: a selection made elsewhere while
        // this screen was torn down (`didDisappear()` cancels `selectionPublisher()` along with
        // everything else) is otherwise never picked up until the *next* external change — the
        // cached `MainWindowCoordinator`/`SidebarVM` survive a window close/reopen, so this is a
        // real, reachable gap, not a hypothetical one.
        desiredSelection = routing.selection
        requestWorkflowReveal(desiredSelection)
        resolveUnloadedSelection(desiredSelection)
        // Same reasoning for a reveal requested while this screen was unsubscribed: the coordinator
        // still holds it (Design point 5), so pick it up here rather than only via `revealPublisher()`.
        if let reveal = routing.pendingReveal { handleReveal(reveal) }
        if !didSubscribe { subscribeToHistory() }
        subscribeIfNeeded()
        startWorkflowPolling()
        recompute()
    }

    func didDisappear() {
        historyBottomVisible = false
        historyViewportRevision = -1
        taskHistoryLoadTask?.cancel()
        workflowHistoryLoadTask?.cancel()
        taskHistoryLoadTask = nil
        workflowHistoryLoadTask = nil
        taskHistoryRequestedCursor = nil
        workflowHistoryRequestedCursor = nil
        presentationEnabled = false
        presentationEpoch += 1
        pendingPresentationInput = nil
        presentationWorker?.cancel()
        stopWorkflowPolling()
        cancellables.removeAll()
        didSubscribe = false
    }

    func didChangeSearchQuery(_ text: String) {
        searchQuery = text
        recompute()
    }

    func didSelectBackendFilter(_ backend: String) {
        selectedBackend = backend
        recompute()
    }

    func didSelect(_ destination: MonitorDestination?) {
        selectionRevision += 1
        desiredSelection = destination
        // A List binding must acknowledge its interaction synchronously. Reuse the settled
        // indexes; the worker still owns full retention and visibility reconciliation.
        if case .task(let id) = destination {
            let representative = indexedExecutionParents[id] != nil
                ? (indexedRepresentatives[id]
                    ?? (indexedWorkflowOwners[id] == nil ? conversationIndex.conversationID(of: id) : id))
                : conversationIndex.conversationID(of: id)
            selection = .task(representative)
        } else {
            selection = destination
        }
        recompute()
        routing.select(destination)
    }

    func didTapNewSession() {
        routing.openNewSession()
    }

    // MARK: - Collapsible tree (settled plan, Design points 1-5)

    func didToggleExpansion(taskID: String) {
        nextPresentationTransaction = Transaction(animation: PbMotion.disclosure(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        if taskID.hasPrefix("group:"),
           (indexedGroupConversations[taskID]?.count ?? 0) <= 1 { return }
        if taskID.hasPrefix("workflow:") || taskID.hasPrefix("group:") {
            if !expandedExecutionParents.insert(taskID).inserted {
                expandedExecutionParents.remove(taskID)
                if case .task(let selectedID) = desiredSelection, executionParent(of: selectedID) == taskID {
                    let parent: MonitorDestination = taskID.hasPrefix("workflow:")
                        ? .workflowRun(String(taskID.dropFirst(9))) : .group(String(taskID.dropFirst(6)))
                    selectionRevision += 1
                    desiredSelection = parent
                    selection = parent
                    routing.select(parent)
                }
            }
            recompute()
            return
        }
        if collapsedTaskIDs.contains(taskID) {
            collapsedTaskIDs.remove(taskID)
        } else {
            collapsedTaskIDs.insert(taskID)
        }
        recompute()
    }

    /// ← collapses the selected row (or, on a collapsed/leaf row, moves selection to its parent); →
    /// expands it. Attached to the `List` itself (Design point 2a), never the window, so ↑/↓ and
    /// typing in the search field are unaffected.
    func didPressMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: didPressCollapse()
        case .right: didPressExpand()
        default: break
        }
    }

    // MARK: - Install banner actions (settled plan, section 5)

    func didTapInstallBannerPrimary() {
        switch installState {
        case .needsGit:
            Task { [weak self] in await self?.useCase.install() }
        case .needsUv:
            publishInstallUvDialog()
        case .failed:
            Task { [weak self] in await self?.useCase.retry() }
        case .unresolved:
            Task { [weak self] in await self?.useCase.checkAgain() }
        case .running:
            break
        case .idle, .installed:
            if let need = currentInstallNeed { publishInstallOrUpdateDialog(need: need) }
        }
    }

    func didTapInstallBannerSecondary() {
        if case .unresolved = installState { publishInstallAnywayDialog() }
    }

    func didTapInstallBannerDismiss() {
        useCase.reset()
    }

    // MARK: - Private Methods

    func applyExternalSelection(_ destination: MonitorDestination?) {
        guard destination != desiredSelection else { return }
        desiredSelection = destination
        requestWorkflowReveal(desiredSelection)
        resolveUnloadedSelection(desiredSelection)
        recompute()
    }

    func recompute() {
        guard presentationEnabled else { return }
        let start = MonitorMetrics.begin()
        let nextConnected = latestListError == nil && latestHasListed
        if isConnected != nextConnected { isConnected = nextConnected }
        let nextConnection = useCase.connectionLine
        if connectionLine != nextConnection { connectionLine = nextConnection }
        let input = presentationInput()
        schedulePresentation(input, requestedStart: start)
        MonitorMetrics.end(start, stage: .sidebarPreparation)
    }

    func presentationInput() -> SidebarPresentationInput {
        SidebarPresentationInput(tasks: latestTasks, runs: workflowRuns, definitions: workflowDefinitions,
            titles: capturedTitles(), catalog: latestCatalog, search: searchQuery, backend: selectedBackend,
            collapsed: collapsedTaskIDs, expanded: expandedExecutionParents, selection: desiredSelection,
            siblings: lastKnownSiblingsByMember, reveal: pendingRevealToApply, workflowReveal: pendingWorkflowRevealID,
            now: currentDate(), calendar: Calendar.current)
    }

    func capturedTitles() -> [String: String] {
        Dictionary(latestTasks.map { ($0.taskID, latestTitles[$0.taskID] ?? useCase.title($0.taskID)) }, uniquingKeysWith: { _, new in new })
    }

    func schedulePresentation(_ input: SidebarPresentationInput, requestedStart: UInt64?) {
        pendingPresentationScheduledStart = MonitorMetrics.begin()
        if let active = activePresentationInput {
            pendingPresentationStart = requestedStart
            pendingPresentationInput = input
            if !input.hasSameSources(as: active) {
                presentationRevision += 1
                presentationWorker?.cancel()
            }
            return
        }
        pendingPresentationStart = requestedStart
        startPresentation(input)
    }

    func startPresentation(_ input: SidebarPresentationInput) {
        let revision = presentationRevision
        let epoch = presentationEpoch
        let latencyStart = pendingPresentationStart ?? MonitorMetrics.begin()
        pendingPresentationStart = nil
        let schedulingStart = pendingPresentationScheduledStart
        pendingPresentationScheduledStart = nil
        let transaction = nextPresentationTransaction
        nextPresentationTransaction = Transaction()
        activePresentationInput = input
        let build = presentationBuild
        let worker = Task.detached(priority: .utility) { () -> SidebarPresentationBuild? in
            MonitorMetrics.end(schedulingStart, stage: .sidebarScheduling)
            return await build(input)
        }
        presentationWorker = worker
        presentationCompletion = Task { [weak self] in
            let result = await worker.value
            guard let self else { return }
            if let result, presentationEnabled, epoch == presentationEpoch, revision == presentationRevision {
                withTransaction(transaction) { applyPresentation(result) }
                MonitorMetrics.end(latencyStart, stage: .sidebarUpdateLatency)
            }
            presentationWorker = nil
            presentationCompletion = nil
            activePresentationInput = nil
            if presentationEnabled, let pending = pendingPresentationInput {
                pendingPresentationInput = nil
                startPresentation(pending)
            } else if presentationEnabled {
                continueVisibleHistoryLoading()
            }
        }
    }

    func applyPresentation(_ result: SidebarPresentationBuild) {
        let start = MonitorMetrics.begin()
        var writes = 0
        let state = result.presentation
        let contentChanged = sections != state.sections || savedWorkflows != state.savedWorkflows
        if sections != state.sections { sections = state.sections; writes += 1 }
        if savedWorkflows != state.savedWorkflows { savedWorkflows = state.savedWorkflows; writes += 1 }
        if contentChanged { historyPresentationRevision += 1; writes += 1 }
        if backendTabs != state.backendTabs { backendTabs = state.backendTabs; writes += 1 }
        if catalogUnavailableNote != state.catalogUnavailableNote { catalogUnavailableNote = state.catalogUnavailableNote; writes += 1 }
        if selectedBackend != state.selectedBackend { selectedBackend = state.selectedBackend; writes += 1 }
        if selection != state.selection { selection = state.selection; writes += 1 }
        conversationIndex = result.conversationIndex
        indexedWorkflowOwners = result.owners
        indexedWorkflowChildren = result.children
        collapsedTaskIDs = result.collapsed
        expandedExecutionParents = result.expanded
        lastKnownSiblingsByMember = result.siblings
        indexedGroupConversations = result.groups
        indexedRepresentatives = result.representatives
        indexedExecutionParents = result.executionParents
        pendingWorkflowRevealID = result.remainingWorkflowReveal
        if let requestID = result.consumedReveal, pendingRevealToApply?.requestID == requestID {
            pendingRevealToApply = nil
            routing.consumeReveal(requestID: requestID)
        }
        let empty = computeEmptyStateMessage()
        if emptyStateMessage != empty { emptyStateMessage = empty; writes += 1 }
        let loading = computeShowsLoadingSkeleton()
        if showsLoadingSkeleton != loading { showsLoadingSkeleton = loading; writes += 1 }
        MonitorMetrics.end(start, stage: .sidebarApply, renderingWrites: writes)
        recordContentReady(start)
    }

    private func recordContentReady(_ start: UInt64?) {
        guard !sections.isEmpty || !workflowDefinitions.isEmpty || !workflowRuns.isEmpty else { return }
        MonitorMetrics.end(start, stage: .sidebarContentReady)
    }

    // MARK: - Reveal (settled plan, Design point 5)

    func handleReveal(_ reveal: PendingReveal) {
        pendingRevealToApply = reveal
        resolveUnloadedSelection(.task(reveal.taskID))
        recompute()
    }

    // MARK: - Keyboard (Design point 2a)

    private func didPressCollapse() {
        guard case .task(let id)? = selection else { return }
        if !collapsedTaskIDs.contains(id), hasChildren(id) {
            collapsedTaskIDs.insert(id)
            recompute()
        } else if let parentID = conversationIndex.ancestors(ofConversationContaining: id).last?.id {
            routing.select(.task(parentID))
        }
    }

    private func didPressExpand() {
        guard case .task(let id)? = selection, collapsedTaskIDs.contains(id) else { return }
        collapsedTaskIDs.remove(id)
        recompute()
    }

    private func hasChildren(_ id: String) -> Bool {
        !conversationIndex.children(of: id).isEmpty
    }
}
