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
import PbTerminal
import PbUI
import PbUtilities

// MARK: - SidebarUseCase

/// The sidebar's data needs over `TaskListRepository` and `TerminalSessionRegistry`.
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
    
    func title(_ taskID: String) -> String
    
    /// A live embedded session for `taskID`, if any (drives the terminal glyph).
    func session(forTask taskID: String) -> TerminalSession?
    /// Interactive sessions that have not ended, plus a publisher for when the set changes.
    var interactiveSessions: [TerminalSession] { get }
    func sessionsPublisher() -> AnyPublisher<[TerminalSession], Never>
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
    private(set) var interactiveRows: [InteractiveSessionRowModel] = []
    private(set) var recentRows: [TaskRowModel] = []
    private(set) var listErrorMessage: String?
    /// Shown only when a listing exists, it has no tasks, and there is no error (F4-43).
    private(set) var isEmptyState = false
    private(set) var isConnected = false
    private(set) var connectionLine: String
    private(set) var availableBackends: [String] = []
    private(set) var selectedBackend = "all"
    private(set) var searchQuery = ""
    /// Stored (not computed) so `@Observable` tracks it: `routing.selection`'s own type is a
    /// protocol existential, invisible to Observation, so a plain forwarding computed property
    /// would never mark the view as needing a redraw when the coordinator's selection changes
    /// from elsewhere (e.g. "Open parent" in `TaskDetailView`). Initialised from `routing.selection`
    /// and kept live by the `selectionPublisher()` subscription in `subscribeIfNeeded()`.
    private(set) var selection: MonitorDestination?
    
    // MARK: - Private Properties
    
    @ObservationIgnored private let useCase: any SidebarUseCase
    @ObservationIgnored private let routing: any SidebarRouting
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var latestTasks: [TaskInfo] = []
    @ObservationIgnored private var latestListError: ToolError?
    @ObservationIgnored private var latestHasListed = false
    
    // MARK: - Init
    
    init(useCase: any SidebarUseCase, routing: any SidebarRouting) {
        self.useCase = useCase
        self.routing = routing
        self.connectionLine = useCase.connectionLine
        self.selection = routing.selection
    }
    
    // MARK: - SidebarViewModel Methods
    
    func didAppear() {
        // Re-sync unconditionally, even if already subscribed: a selection made elsewhere while
        // this screen was torn down (`didDisappear()` cancels `selectionPublisher()` along with
        // everything else) is otherwise never picked up until the *next* external change — the
        // cached `MainWindowCoordinator`/`SidebarVM` survive a window close/reopen, so this is a
        // real, reachable gap, not a hypothetical one.
        selection = routing.selection
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
        recompute()
    }
    
    func didSelect(_ destination: MonitorDestination?) {
        routing.select(destination)
    }
    
    func didTapNewSession() {
        routing.openNewSession()
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
                availableBackends = Array(Set(tasks.map(\.backend))).sorted()
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.listErrorPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                latestListError = error
                listErrorMessage = error?.message
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasListed in
                guard let self else { return }
                latestHasListed = hasListed
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.sessionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        
        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        
        routing.selectionPublisher()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.selection, on: self)
            .store(in: &cancellables)
    }
    
    /// Recomputes every derived list from `latestTasks`/`latestListError`/`latestHasListed`, the
    /// current search query and backend filter — mirrors the old `SidebarView.body`'s inline
    /// `Lineage.sections`/filtering exactly.
    private func recompute() {
        isConnected = latestListError == nil && latestHasListed
        connectionLine = useCase.connectionLine
        
        let query = searchQuery.trimmingCharacters(in: .whitespaces).lowercased()
        let backend = selectedBackend
        let sections = Lineage.sections(latestTasks) { [useCase] task in
            (backend == "all" || task.backend == backend)
            && (query.isEmpty
                || useCase.title(task.taskID).lowercased().contains(query)
                || task.taskID.lowercased().contains(query)
                || task.repoPath.lowercased().contains(query))
        }
        
        runningRows = sections.running.flatMap(flattenedRows)
        recentRows = sections.recent.flatMap(flattenedRows)
        parallelGroups = sections.parallel
        
        interactiveRows = useCase.interactiveSessions.map {
            InteractiveSessionRowModel(id: $0.id, backend: $0.backend, title: $0.title)
        }
        
        isEmptyState = latestHasListed && latestTasks.isEmpty && latestListError == nil
    }
    
    private func flattenedRows(_ root: TaskNode) -> [TaskRowModel] {
        root.flattened().map { entry in
            let task = entry.node.task
            let hasLiveSession = useCase.session(forTask: task.taskID).map { !$0.ended } ?? false
            return TaskRowModel(
                id: task.taskID,
                backend: task.backend,
                title: useCase.title(task.taskID),
                statusLabel: task.status.label,
                statusColor: StatusColor.of(task.status),
                ageText: Format.age(task.startedAt),
                indent: entry.indent,
                metaText: metaText(for: entry.node),
                hasLiveSession: hasLiveSession,
                isRunning: task.status.isRunning,
                startedAt: task.startedAt,
                durationSeconds: task.durationSeconds
            )
        }
    }
    
    private func metaText(for node: TaskNode) -> String {
        var parts = [Format.repo(node.task.repoPath)]
        if node.descendantCount > 0 { parts.append("\(node.descendantCount) sub-task\(node.descendantCount == 1 ? "" : "s")") }
        if let freedom = node.task.freedom { parts.append(freedom) }
        return parts.joined(separator: " · ")
    }
}
