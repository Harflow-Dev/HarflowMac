//
//  ParallelVM.swift
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

// MARK: - ParallelUseCase

/// The Parallel screen's data needs over `TaskListRepository`, `TaskSnapshotRepository`,
/// `TaskActionRepository`, `EventStreamRepository` and `TakeoverService`.
@Mockable
@MainActor
protocol ParallelUseCase: Sendable {

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never>
    func busyPublisher() -> AnyPublisher<Set<String>, Never>
    func outcomesPublisher() -> AnyPublisher<[String: String], Never>
    /// Titles load off-main, separately from the listing itself (F4-11/MS-LIST-5, the same gap
    /// Codex review caught on `SidebarVM` in Phase 4b) — a column must refresh when one arrives even
    /// though the listing itself did not change.
    func titlesPublisher() -> AnyPublisher<[String: String], Never>

    /// The fresh listing entry for a member (F4-40: "using the fresh listing entry") — never a
    /// cached copy retained by this screen.
    func task(_ id: String) -> TaskInfo?
    func title(_ taskID: String) -> String

    /// Decision 6: one lease per member, acquired while its column is on screen.
    func acquireEventLease(_ taskID: String) -> any EventStreamLease
    func items(for taskID: String) -> [TimelineItem]
    func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never>
    func prompt(for taskID: String) -> String?
    
    func runningInSubtrees(of ids: [String]) -> [String]
    func cancelAll(_ ids: [String]) async
    
    /// Dispatches into `TakeoverService` synchronously; the VM routes to the task screen immediately
    /// after calling this. Take over always opens Terminal.app.
    func beginTakeover(taskID: String)
}

// MARK: - ParallelRouting

/// Navigation the Parallel screen performs: routing to a member's own task screen, either from
/// "Open task" or right after an embedded takeover.
@Mockable
@MainActor
protocol ParallelRouting: Sendable {
    func selectTask(_ taskID: String)
}

// MARK: - ParallelLayout

/// The column-width rule (F4-40): `max(360, 900 / memberCount)`. A pure function so it is testable
/// without a SwiftUI rendering harness.
enum ParallelLayout {
    static func columnWidth(memberCount: Int) -> CGFloat {
        max(360, 900 / CGFloat(max(1, memberCount)))
    }
}

// MARK: - ParallelVM

/// View model for the Parallel screen: one column per group member, ported from the old
/// `ParallelView.swift`/`ParallelColumn` with no behaviour change. The column's outcome line is always
/// secondary-coloured; only TaskDetail's header turns red for "Refused".
@Observable
@MainActor
final class ParallelVM: ParallelViewModel {
    
    // MARK: - ParallelViewModel Properties
    
    let groupName: String
    private(set) var headerSubtitle = ""
    private(set) var showPrompt = false
    private(set) var canCancelAll = false
    private(set) var isEmpty = false
    private(set) var columns: [ParallelColumnModel] = []
    private(set) var footerText = ParallelVM.fallbackFooter
    
    // MARK: - Private Properties
    
    static let fallbackFooter = "Enforcement differs between these agents; see each task's details."
    
    @ObservationIgnored private let useCase: any ParallelUseCase
    @ObservationIgnored private let routing: any ParallelRouting
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var itemCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var leases: [String: any EventStreamLease] = [:]
    @ObservationIgnored private var itemsByTask: [String: [TimelineItem]] = [:]
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var latestTasks: [TaskInfo] = []
    @ObservationIgnored private var latestSnapshots: [String: TaskInfo] = [:]
    @ObservationIgnored private var latestBusy: Set<String> = []
    @ObservationIgnored private var latestOutcomes: [String: String] = [:]
    @ObservationIgnored private var memberIDs: [String] = []
    
    // MARK: - Init
    
    init(groupName: String, useCase: any ParallelUseCase, routing: any ParallelRouting) {
        self.groupName = groupName
        self.useCase = useCase
        self.routing = routing
    }
    
    // MARK: - ParallelViewModel Methods
    
    func didAppear() {
        subscribeIfNeeded()
    }
    
    /// Idempotent teardown (root AGENTS.md rule 7): releases every outstanding lease, cancels every
    /// subscription, and resets `didSubscribe` so a reappearing screen (the detail pane can be
    /// revisited) subscribes and re-acquires leases fresh.
    func didDisappear() {
        cancellables.removeAll()
        itemCancellables.removeAll()
        for lease in leases.values { lease.release() }
        leases.removeAll()
        itemsByTask.removeAll()
        memberIDs.removeAll()
        didSubscribe = false
    }
    
    func didTapViewPrompt() {
        showPrompt.toggle()
        recompute()
    }
    
    func didTapCancelAll() {
        guard canCancelAll else { return }
        let ids = memberIDs
        publishDialog("Cancel every running task in this group?") {
            AlertAction(title: "Cancel all", role: .destructive) { [useCase] in
                Task { await useCase.cancelAll(useCase.runningInSubtrees(of: ids)) }
            }
        }
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
                recomputeMembersAndLeases()
            }
            .store(in: &cancellables)
        
        useCase.snapshotsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in
                guard let self else { return }
                latestSnapshots = snapshots
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.busyPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                guard let self else { return }
                latestBusy = busy
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.outcomesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomes in
                guard let self else { return }
                latestOutcomes = outcomes
                recompute()
            }
            .store(in: &cancellables)
        
        // Titles load independently of the listing (Codex review finding): a column must refresh
        // when it changes on its own, not only when an unrelated publisher happens to fire afterward.
        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }
    
    /// Recomputes which tasks belong to this group (Lineage's own definition — a group's top-level
    /// members) and diffs the member set against the currently-leased one, acquiring a lease for
    /// every newly-seen member and releasing one for every member that dropped out.
    private func recomputeMembersAndLeases() {
        let group = Lineage.sections(latestTasks).parallel.first { $0.name == groupName }
        let members = group?.members.map(\.task) ?? []
        let newIDs = members.map(\.taskID)
        let newIDSet = Set(newIDs)
        let oldIDSet = Set(memberIDs)
        
        for id in newIDSet.subtracting(oldIDSet) { acquireLease(id) }
        for id in oldIDSet.subtracting(newIDSet) { releaseLease(id) }
        memberIDs = newIDs
        
        canCancelAll = group?.anyRunning == true
        isEmpty = members.isEmpty
        
        let freedoms = Set(members.compactMap(\.freedom)).sorted().joined(separator: ", ")
        let repos = Set(members.map { Format.repo($0.repoPath) }).sorted().joined(separator: ", ")
        headerSubtitle = "\(members.count) agents · \(freedoms) · \(repos)"
        + (group?.startedAt.map { " · started \(Format.time($0))" } ?? "")
        
        recompute()
    }
    
    private func acquireLease(_ taskID: String) {
        guard leases[taskID] == nil else { return }
        leases[taskID] = useCase.acquireEventLease(taskID)
        itemsByTask[taskID] = useCase.items(for: taskID)
        itemCancellables[taskID] = useCase.itemsPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                itemsByTask[taskID] = items
                recompute()
            }
    }
    
    private func releaseLease(_ taskID: String) {
        leases[taskID]?.release()
        leases[taskID] = nil
        itemCancellables[taskID]?.cancel()
        itemCancellables[taskID] = nil
        itemsByTask[taskID] = nil
    }
    
    /// Rebuilds every column from the freshest available state — always re-reading `useCase.task(_:)`
    /// rather than a value cached at the last `tasksPublisher` emission, so a busy/outcome/snapshot-
    /// only update still reflects the task's current fields (F4-40).
    private func recompute() {
        let members = memberIDs.compactMap { useCase.task($0) }
        columns = members.map(makeColumnModel)
        
        let footerTasks = memberIDs.compactMap { latestSnapshots[$0] ?? useCase.task($0) }
        footerText = EnforcementText.common(footerTasks) ?? Self.fallbackFooter
    }
    
    private func makeColumnModel(for task: TaskInfo) -> ParallelColumnModel {
        let taskID = task.taskID
        let metaLine = [task.backend, task.reasoningEffort.map { "effort \($0)" }, task.sessionID.map { "session \($0.prefix(8))" }]
            .compactMap(\.self)
            .joined(separator: " · ")

        return ParallelColumnModel(
            id: taskID,
            task: task,
            title: useCase.title(taskID),
            metaLine: metaLine,
            isBusy: latestBusy.contains(taskID),
            outcomeMessage: latestOutcomes[taskID],
            showPrompt: showPrompt,
            prompt: useCase.prompt(for: taskID),
            items: itemsByTask[taskID] ?? [],
            // F4-40: the snapshot only — no fallback to `task.summary`, unlike `ChangesPane`.
            summary: latestSnapshots[taskID]?.summary,
            onTapTakeover: { [weak self] in self?.didTapTakeover(taskID: taskID) },
            onTapOpenTask: { [weak self] in self?.routing.selectTask(taskID) }
        )
    }
    
    private func didTapTakeover(taskID: String) {
        guard let task = useCase.task(taskID) else { return }
        let isRunning = task.status.isRunning
        let title = isRunning ? "Take over this task?" : "Continue this session in a terminal?"
        let buttonTitle = isRunning ? "Stop it and take over" : "Continue in terminal"
        let message = "The headless run is stopped first if it is still going, then the same conversation opens in Terminal.app. It runs "
        + "under your own default permissions, not \(task.freedom ?? "this task's freedom")."
        publishDialog(title, description: message) {
            AlertAction(title: buttonTitle) { [weak self] in
                guard let self else { return }
                // Dispatches synchronously into a service-owned task, then routes immediately —
                // decision 5's call path, kept exact (`ParallelView.swift:~123-127`).
                useCase.beginTakeover(taskID: taskID)
                routing.selectTask(taskID)
            }
        }
    }
}
