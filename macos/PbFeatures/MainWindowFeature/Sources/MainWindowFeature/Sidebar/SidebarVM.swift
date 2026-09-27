//
//  SidebarVM.swift
//  MainWindowFeature
//

import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import PbUtilities
import SwiftUI

// MARK: - SidebarUseCase

/// The sidebar's data needs over `TaskListRepository`.
@Mockable
@MainActor
protocol SidebarUseCase: Sendable {

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never>
    func hasListedPublisher() -> AnyPublisher<Bool, Never>
    /// Titles load off-main, separately from the listing itself (F4-11/MS-LIST-5) — a row must
    /// refresh when one arrives even though `tasks` itself did not change.
    func titlesPublisher() -> AnyPublisher<[String: String], Never>

    var tasks: [TaskInfo] { get }
    var listError: ToolError? { get }
    var hasListed: Bool { get }
    var connectionLine: String { get }

    // MARK: Backend catalog (Monitor piece 6)

    var backendCatalog: BackendCatalog { get }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never>

    func title(_ taskID: String) -> String

    // MARK: Install (settled plan, section 5)

    func installStatePublisher() -> AnyPublisher<InstallState, Never>
    var installState: InstallState { get }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never>
    var lastCheckMessage: String? { get }
    func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never>
    var installAnywayBlockedMessage: String? { get }
    /// Classifies `error` against the currently located `polybridge-ctl`/`polybridge-setup`
    /// presence; `nil` when `error` isn't an install need.
    func installNeed(for error: ToolError) -> InstallNeed?
    /// Where the next install would land, for confirmation-dialog copy only.
    func installDestination() -> String?
    func install() async
    func installUvThenPolybridge() async
    func retry() async
    func checkAgain() async
    @discardableResult
    func installAnyway() async -> Bool
    func reset()
}

// MARK: - PendingReveal

/// A navigation-triggered request to reveal (expand the ancestors of) a task in the sidebar's tree —
/// owned by `MainWindowCoordinator` (settled plan, Design point 5's "coordinator owns the pending
/// reveal") rather than by `SidebarVM`, so it survives a window close/reopen even though the sidebar
/// is unsubscribed while hidden. `requestID` is fresh on every request, repeats included — plain
/// `selection` reuses the same value on a repeated navigation to an already-selected task, and its
/// own `didSet` drops that repeat (see `MainWindowCoordinator.selection`), so a `PassthroughSubject`
/// keyed only on the task id would silently do the same. A fresh id per request sidesteps that.
struct PendingReveal: Equatable, Sendable {
    let taskID: String
    let requestID: UUID
}

// MARK: - SidebarRouting

/// Navigation the sidebar performs, plus the read side of the same selection state
/// `MainWindowCoordinator` owns (decision in this dispatch's `AGENTS.md`): the sidebar's
/// `List(selection:)` binding needs to reflect a selection made elsewhere (e.g. "Open parent" in
/// the still-app-target `TaskDetailView`), not just its own taps.
@Mockable
@MainActor
protocol SidebarRouting: Sendable {
    var selection: MonitorDestination? { get }
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never>
    /// `nil` clears the selection — `List(selection:)` writes `nil` on deselection, and the old
    /// `List(selection: $model.selection)` accepted that directly.
    func select(_ destination: MonitorDestination?)
    func openNewSession()

    // MARK: Pending reveal (settled plan, Design point 5)

    /// The latest unconsumed navigation-triggered reveal, or `nil`. Read on `didAppear()` so a
    /// reveal requested while the sidebar was unsubscribed (window closed) is not lost.
    var pendingReveal: PendingReveal? { get }
    func revealPublisher() -> AnyPublisher<PendingReveal, Never>
    /// Marks `requestID`'s reveal consumed — a no-op if it has already been superseded by a later
    /// one (a fresh request replaces the pending value before this is called).
    func consumeReveal(requestID: UUID)
}

// MARK: - SidebarVM

/// View model for the Sidebar screen: search/backend filtering, sections, and the interactive
/// sessions list, ported from the old `SidebarView.swift` with no behaviour change.
@Observable
@MainActor
final class SidebarVM: SidebarViewModel {
    
    // MARK: - SidebarViewModel Properties
    
    private(set) var runningRows: [TaskRowModel] = []
    private(set) var parallelGroups: [ParallelGroup] = []
    private(set) var recentRows: [TaskRowModel] = []
    private(set) var listErrorMessage: String?
    /// The precedence-ordered empty-state message for the list body, or `nil` when real content (or
    /// a connection/error/banner state that already owns the space) makes one unnecessary — see
    /// `computeEmptyStateMessage()` for the exact rule (Monitor piece 6, Review round 1 item 3).
    /// Written from `SidebarVM+InstallBanner.swift`'s `recomputeInstallBanner()` too (Code review
    /// round 1, finding 4 — the message depends on `installBannerModel`, so a banner change must
    /// recompute it), so it cannot be `private(set)` — `private` is file-scoped in Swift, same
    /// reasoning as `installBannerModel` just below.
    var emptyStateMessage: String?
    private(set) var isConnected = false
    private(set) var connectionLine: String
    /// "All" plus every backend polybridge reports (registry order), plus any backend seen only in
    /// task history (alphabetical) — Design point 3/Review round 1 item 5.
    private(set) var backendTabs: [BackendTab] = [.all]
    private(set) var selectedBackend = "all"
    /// The tab keyboard focus ring currently sits on — independent of `selectedBackend`, since
    /// arrowing through tabs must not filter the list until Space/Return confirms (Review round 1
    /// item 4).
    private(set) var focusedBackendTab = "all"
    /// A quiet note shown near the tab row when the catalog is degraded with nothing carried over —
    /// "Backend list unavailable — update polybridge." (Review round 1 item 2). `nil` otherwise.
    private(set) var catalogUnavailableNote: String?
    private(set) var searchQuery = ""
    /// Stored (not computed) so `@Observable` tracks it: `routing.selection`'s own type is a
    /// protocol existential, invisible to Observation, so a plain forwarding computed property
    /// would never mark the view as needing a redraw when the coordinator's selection changes
    /// from elsewhere (e.g. "Open parent" in `TaskDetailView`). Initialised from `routing.selection`
    /// and kept live by the `selectionPublisher()` subscription in `subscribeIfNeeded()`.
    private(set) var selection: MonitorDestination?
    /// The install/update banner to show in place of the red error section, or `nil` when nothing
    /// needs surfacing (settled plan, section 5's precedence rules). Written from
    /// `SidebarVM+InstallBanner.swift` too, so it cannot be `private(set)` — `private` is
    /// file-scoped in Swift (same reasoning as `TaskDetailVM`'s own cross-file-written properties).
    /// It stays non-public regardless: no external module can write it.
    var installBannerModel: InstallBanner.Model?

    // MARK: - Private Properties

    // The properties below are read or written from `SidebarVM+InstallBanner.swift` as well as this
    // file, so — same reasoning as `installBannerModel` above — they cannot be `private`.
    @ObservationIgnored let useCase: any SidebarUseCase
    @ObservationIgnored private let routing: any SidebarRouting
    @ObservationIgnored var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    // `latestTasks`/`collapsedTaskIDs`/`lastKnownSiblingsByMember` are also read/written from
    // `SidebarVM+Retention.swift` (Review round 1, item 4's "retention while open"), so — same
    // reasoning as the install-banner properties above — they cannot be `private`.
    @ObservationIgnored var latestTasks: [TaskInfo] = []
    @ObservationIgnored var latestListError: ToolError?
    @ObservationIgnored private var latestHasListed = false
    @ObservationIgnored private var latestCatalog: BackendCatalog
    @ObservationIgnored var installState: InstallState = .idle
    @ObservationIgnored var lastCheckMessage: String?
    @ObservationIgnored var installAnywayBlockedMessage: String?
    @ObservationIgnored var currentInstallNeed: InstallNeed?
    /// Tasks the person has collapsed in the sidebar's tree — expanded by default (Design point 3).
    /// Lives for the app's lifetime (this VM is cached across window close/reopen); never mutated by
    /// an ordinary `recompute()` — only `didToggleExpansion(taskID:)` and an applied reveal touch it.
    @ObservationIgnored var collapsedTaskIDs: Set<String> = []
    /// A reveal that could not be applied yet because its task was not in `latestTasks` — retried on
    /// every `tasksPublisher` emission until it lands, or replaced by a fresher one.
    @ObservationIgnored private var pendingRevealToApply: PendingReveal?
    /// Every member id ever seen, mapped to its whole conversation's member set as of the last time
    /// that conversation was resolvable directly (Review round 1, item 4 — "retention while open").
    /// Never cleared; only overwritten per member on each recompute. Read when an id is no longer in
    /// `latestTasks` at all (its own record was pruned) to find a still-present sibling and resolve
    /// — and carry collapse state — through the conversation it now identifies.
    @ObservationIgnored var lastKnownSiblingsByMember: [String: Set<String>] = [:]

    // MARK: - Init

    init(useCase: any SidebarUseCase, routing: any SidebarRouting) {
        self.useCase = useCase
        self.routing = routing
        self.connectionLine = useCase.connectionLine
        self.selection = routing.selection
        self.installState = useCase.installState
        self.lastCheckMessage = useCase.lastCheckMessage
        self.installAnywayBlockedMessage = useCase.installAnywayBlockedMessage
        self.latestCatalog = useCase.backendCatalog
        recomputeInstallBanner()
        recomputeBackendTabs()
    }

    // MARK: - SidebarViewModel Methods

    func didAppear() {
        // Re-sync unconditionally, even if already subscribed: a selection made elsewhere while
        // this screen was torn down (`didDisappear()` cancels `selectionPublisher()` along with
        // everything else) is otherwise never picked up until the *next* external change — the
        // cached `MainWindowCoordinator`/`SidebarVM` survive a window close/reopen, so this is a
        // real, reachable gap, not a hypothetical one.
        selection = normalized(routing.selection)
        // Same reasoning for a reveal requested while this screen was unsubscribed: the coordinator
        // still holds it (Design point 5), so pick it up here rather than only via `revealPublisher()`.
        if let reveal = routing.pendingReveal { handleReveal(reveal) }
        subscribeIfNeeded()
    }

    func didDisappear() {
        cancellables.removeAll()
        didSubscribe = false
    }

    func didChangeSearchQuery(_ text: String) {
        searchQuery = text
        recompute()
    }

    func didSelectBackendFilter(_ backend: String) {
        selectedBackend = backend
        focusedBackendTab = backend
        recompute()
    }

    // MARK: - Backend tab row keyboard (Monitor piece 6, Review round 1 item 4)

    /// ←/→ moves the tab-row's own focus ring, independent of `selectedBackend` — Space/Return
    /// (`didPressBackendTabConfirm()`) is what actually filters. Scoped entirely to the tab row by
    /// the view (`BackendTabRow`'s own `.focusable()`), never the task tree's ←/→ or the search
    /// field.
    func didPressBackendTabArrow(_ direction: MoveCommandDirection) {
        guard let index = backendTabs.firstIndex(where: { $0.id == focusedBackendTab }) else { return }
        switch direction {
        case .left: focusedBackendTab = backendTabs[max(0, index - 1)].id
        case .right: focusedBackendTab = backendTabs[min(backendTabs.count - 1, index + 1)].id
        default: break
        }
    }

    func didPressBackendTabConfirm() {
        didSelectBackendFilter(focusedBackendTab)
    }

    func didSelect(_ destination: MonitorDestination?) {
        routing.select(destination)
    }

    func didTapNewSession() {
        routing.openNewSession()
    }

    // MARK: - Collapsible tree (settled plan, Design points 1-5)

    func didToggleExpansion(taskID: String) {
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

    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true

        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                guard let self else { return }
                latestTasks = tasks
                // A reveal that arrived before its task was listed retries here on every listing.
                tryApplyPendingReveal()
                recompute()
            }
            .store(in: &cancellables)

        useCase.listErrorPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                latestListError = error
                currentInstallNeed = error.flatMap { useCase.installNeed(for: $0) }
                listErrorMessage = currentInstallNeed == nil ? error?.message : nil
                recomputeInstallBanner()
                recompute()
            }
            .store(in: &cancellables)

        subscribeToInstallState()

        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasListed in
                guard let self else { return }
                latestHasListed = hasListed
                recompute()
            }
            .store(in: &cancellables)

        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)

        useCase.backendCatalogPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] catalog in
                guard let self else { return }
                latestCatalog = catalog
                recompute()
            }
            .store(in: &cancellables)

        routing.selectionPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] destination in
                guard let self else { return }
                selection = normalized(destination)
            }
            .store(in: &cancellables)

        routing.revealPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reveal in self?.handleReveal(reveal) }
            .store(in: &cancellables)
    }
    
    /// Recomputes every derived list from `latestTasks`/`latestListError`/`latestHasListed`, the
    /// current search query and backend filter — Running/Recent are built from conversations (piece
    /// 7); Parallel groups stay task-level, unchanged (Review round 1, item 3). Never mutates
    /// `collapsedTaskIDs` itself — an ordinary recompute (a new listing, a search keystroke) must
    /// never re-expand a row the person collapsed.
    private func recompute() {
        isConnected = latestListError == nil && latestHasListed
        connectionLine = useCase.connectionLine
        recomputeBackendTabs()
        // Before this listing's own membership overwrites the remembered map: if a conversation's
        // own collapsed id just vanished (retention pruned its first member), move the collapse to
        // whichever surviving sibling now identifies it.
        migrateCollapsedIDsForRetention()

        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let backend = selectedBackend
        let isFilterActive = !query.isEmpty || backend != "all"
        func matches(_ task: TaskInfo) -> Bool {
            (backend == "all" || task.backend == backend)
            && (query.isEmpty
                || useCase.title(task.taskID).lowercased().contains(query)
                || task.taskID.lowercased().contains(query)
                || task.repoPath.lowercased().contains(query))
        }
        let sections = Lineage.conversationSections(latestTasks, matches: matches)
        // Retention membership is recorded from the UNFILTERED tree (Codex review round 2, finding
        // 3), never `sections` above: an active search/backend filter can hide a whole conversation
        // — and any follow-up it gets while hidden — from `sections.running`/`sections.recent`
        // entirely (`keep(tree)`), so recording only from the filtered tree would forget that
        // conversation's membership for as long as the filter stays active, and a prune during that
        // window could never hand off once the filter clears.
        recordMembership(Lineage.conversationSections(latestTasks))

        // Filter forces ancestors of an actual match expanded, for *display only* — this never
        // touches `collapsedTaskIDs`, so clearing the filter restores exactly what the person had
        // collapsed (Design point 5's "Filter" rule).
        let forcedExpandedIDs: Set<String> = isFilterActive
            ? Set(latestTasks.filter(matches).flatMap { task in
                Lineage.conversationAncestors(of: task.taskID, in: latestTasks).map(\.id)
            })
            : []

        runningRows = sections.running.flatMap { flattenedRows($0, forcedExpandedIDs: forcedExpandedIDs) }
        recentRows = sections.recent.flatMap { flattenedRows($0, forcedExpandedIDs: forcedExpandedIDs) }
        parallelGroups = Lineage.sections(latestTasks, matches: matches).parallel

        // Retention while open (Review round 1, item 4): re-normalising the CURRENT selection on
        // every recompute (not just on a fresh `selectionPublisher()` event) is what lets the
        // highlighted row follow a conversation whose own id just changed underneath an unchanged
        // selection — idempotent for the ordinary case, where the id has not moved.
        selection = normalized(selection)

        emptyStateMessage = computeEmptyStateMessage()
    }

    // MARK: - Backend tabs (Monitor piece 6)

    /// Tabs = "All" + every backend polybridge reports (registry order) + any backend seen only in
    /// task history (alphabetical) — Design point 3/Review round 1 item 5. Also applies the
    /// selection/focus fallback-to-"All" rule (a backend that disappears from both the catalog and
    /// history) and the degraded-with-nothing-carried-over note.
    private func recomputeBackendTabs() {
        var seen = Set<String>()
        var tabs: [BackendTab] = [.all]
        for entry in latestCatalog.entries {
            guard seen.insert(entry.backend).inserted else { continue }
            tabs.append(BackendTab(id: entry.backend, isNotFound: entry.installed == false))
        }
        let historyOnly = Set(latestTasks.map(\.backend)).subtracting(seen).sorted()
        for backend in historyOnly {
            tabs.append(BackendTab(id: backend, isNotFound: false))
        }
        backendTabs = tabs

        if !tabs.contains(where: { $0.id == selectedBackend }) { selectedBackend = "all" }
        if !tabs.contains(where: { $0.id == focusedBackendTab }) { focusedBackendTab = selectedBackend }

        catalogUnavailableNote = (latestCatalog.state == .degraded && latestCatalog.entries.isEmpty)
            ? "Backend list unavailable — update polybridge."
            : nil
    }

    /// Empty-state precedence (Review round 1 item 3): the connection/loading/listing-error/banner
    /// UI gates first — the view shows that instead, so this is only reached once there's genuinely
    /// nothing else to show; any filtered content (running, parallel groups, or recent) suppresses
    /// the message entirely; a non-blank (trimmed) search always wins next; only then does the
    /// selected backend's own reported availability decide the copy.
    ///
    /// Not `private`: `SidebarVM+InstallBanner.swift`'s `recomputeInstallBanner()` calls this too
    /// (Code review round 1, finding 4) — `private` is file-scoped in Swift, same reasoning as
    /// `installState`/`lastCheckMessage` etc. above.
    func computeEmptyStateMessage() -> String? {
        guard latestHasListed, latestListError == nil, installBannerModel == nil else { return nil }
        guard runningRows.isEmpty, parallelGroups.isEmpty, recentRows.isEmpty else { return nil }

        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedQuery.isEmpty else { return "No tasks match \"\(trimmedQuery)\"." }

        guard selectedBackend != "all" else {
            return "No tasks yet. Tasks started through polybridge appear here."
        }
        if latestCatalog.entries.first(where: { $0.backend == selectedBackend })?.installed == false {
            return "\(selectedBackend) wasn't found on your PATH — install its CLI to run \(selectedBackend) tasks."
        }
        return "No \(selectedBackend) tasks yet."
    }

    /// Flattens one conversation tree into rows, hiding the descendants of a collapsed node (unless
    /// `forcedExpandedIDs` overrides it for the current filter) — a node's own row is always kept,
    /// only its subtree can be hidden. Status/age/meta come from the conversation's CURRENT member;
    /// title from its FIRST (Design point 2). Row `id` is the conversation id (its first member),
    /// so a click already selects the whole conversation with no separate normalisation needed.
    private func flattenedRows(_ root: ConversationNode, forcedExpandedIDs: Set<String>) -> [TaskRowModel] {
        var rows: [TaskRowModel] = []
        var hiddenBelowIndent: Int?
        for entry in root.flattenedWithGuides() {
            if let hiddenBelowIndent, entry.indent > hiddenBelowIndent { continue }
            hiddenBelowIndent = nil

            let node = entry.node
            let conversation = node.conversation
            let current = conversation.current
            let hasChildren = !node.children.isEmpty
            let isCollapsed = collapsedTaskIDs.contains(conversation.id) && !forcedExpandedIDs.contains(conversation.id)
            rows.append(TaskRowModel(
                id: conversation.id,
                backend: current.backend,
                title: useCase.title(conversation.first.taskID),
                statusLabel: current.status.label,
                statusColor: StatusColor.of(current.status),
                ageText: Format.age(current.startedAt),
                indent: entry.indent,
                metaText: metaText(for: node, isCollapsed: isCollapsed),
                isRunning: current.status.isRunning,
                startedAt: current.startedAt,
                durationSeconds: current.durationSeconds,
                hasChildren: hasChildren,
                isExpanded: !isCollapsed,
                guides: entry.guides
            ))
            if hasChildren, isCollapsed { hiddenBelowIndent = entry.indent }
        }
        return rows
    }

    /// Expanded: today's "repo · N sub-tasks · freedom" line. Collapsed (Design point 4): the
    /// subtree summary, "N sub-tasks, M running" with "M running" omitted when nothing underneath
    /// is running — a running descendant still counts even though its own row is hidden.
    private func metaText(for node: ConversationNode, isCollapsed: Bool) -> String {
        let current = node.conversation.current
        var parts = [Format.repo(current.repoPath)]
        if node.descendantCount > 0 {
            parts.append(isCollapsed ? collapsedSummary(for: node) : "\(node.descendantCount) sub-task\(node.descendantCount == 1 ? "" : "s")")
        }
        if let freedom = current.freedom { parts.append(freedom) }
        return parts.joined(separator: " · ")
    }

    private func collapsedSummary(for node: ConversationNode) -> String {
        let base = "\(node.descendantCount) sub-task\(node.descendantCount == 1 ? "" : "s")"
        let running = runningDescendantCount(node)
        return running > 0 ? "\(base), \(running) running" : base
    }

    private func runningDescendantCount(_ node: ConversationNode) -> Int {
        node.children.reduce(0) { $0 + ($1.conversation.current.status.isRunning ? 1 : 0) + runningDescendantCount($1) }
    }

    // MARK: - Reveal (settled plan, Design point 5)

    private func handleReveal(_ reveal: PendingReveal) {
        pendingRevealToApply = reveal
        if tryApplyPendingReveal() { recompute() }
    }

    /// Expands `pendingRevealToApply`'s conversation ancestors and consumes it, when its task is
    /// already listed. Leaves it stored (to retry on the next listing) when the task isn't known yet
    /// — Design point 5's "a reveal for a task not yet listed stays pending until data arrives".
    /// Returns whether it applied, so a caller that hasn't already scheduled a `recompute()` (unlike
    /// the `tasksPublisher` sink, which always recomputes anyway) knows whether it needs to.
    @discardableResult
    private func tryApplyPendingReveal() -> Bool {
        guard let reveal = pendingRevealToApply else { return false }
        guard latestTasks.contains(where: { $0.taskID == reveal.taskID }) else { return false }
        for ancestor in Lineage.conversationAncestors(of: reveal.taskID, in: latestTasks) { collapsedTaskIDs.remove(ancestor.id) }
        pendingRevealToApply = nil
        routing.consumeReveal(requestID: reveal.requestID)
        return true
    }

    // MARK: - Keyboard (Design point 2a)

    private func didPressCollapse() {
        guard case .task(let id)? = selection else { return }
        if !collapsedTaskIDs.contains(id), hasChildren(id) {
            collapsedTaskIDs.insert(id)
            recompute()
        } else if let parentID = Lineage.conversationAncestors(of: id, in: latestTasks).last?.id {
            routing.select(.task(parentID))
        }
    }

    private func didPressExpand() {
        guard case .task(let id)? = selection, collapsedTaskIDs.contains(id) else { return }
        collapsedTaskIDs.remove(id)
        recompute()
    }

    private func hasChildren(_ id: String) -> Bool {
        !Lineage.conversationChildren(of: id, in: latestTasks).isEmpty
    }
}
