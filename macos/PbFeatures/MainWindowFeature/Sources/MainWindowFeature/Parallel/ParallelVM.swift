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
    func events(for taskID: String) -> [TaskEvent]
    func items(for taskID: String) -> [TimelineItem]
    func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never>
    func prompt(for taskID: String) -> String?
    /// Whether the member's event log could actually be read the last time it was tailed (Monitor
    /// piece 12, Design point 4) — mirrors `TaskDetailUseCase.eventsAvailability(for:)`/
    /// `eventsAvailabilityPublisher(for:)`, backed by the same `EventStreamRepository`, so a column
    /// can tell "nothing has happened yet" apart from "there is no log to read at all" and show a
    /// skeleton only for the former.
    func eventsAvailability(for taskID: String) -> EventAvailability
    func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never>

    func runningInSubtrees(of ids: [String]) -> [String]
    func cancelAll(_ ids: [String]) async
    /// The durable outcome line a column shows — TaskDetail's own refusal channel.
    func setOutcome(_ id: String, _ text: String?)

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

/// The column-width rule (Monitor piece 12, Design point 3): columns fill the available width rather
/// than a fixed 900pt budget, so there is no empty band on the right when the window is wide — with a
/// 360pt floor, below which columns keep their old fixed width and the row scrolls horizontally
/// instead of squeezing further. A pure function so it is testable without a SwiftUI rendering
/// harness.
enum ParallelLayout {
    /// The width of the hairline `Divider` drawn after every column (`ParallelView`'s `ForEach`) —
    /// subtracted from `availableWidth` before dividing, so `memberCount` columns plus their dividers
    /// together account for the whole row rather than overflowing it by a few points.
    static let dividerWidth: CGFloat = 1

    static func columnWidth(memberCount: Int, availableWidth: CGFloat) -> CGFloat {
        let count = max(1, memberCount)
        let usableWidth = max(0, availableWidth - CGFloat(count) * dividerWidth)
        return max(360, usableWidth / CGFloat(count))
    }
}

// MARK: - ParallelVM

/// View model for the Parallel screen: one column per group member, ported from the old
/// `ParallelView.swift`/`ParallelColumn` with no behaviour change. The column's outcome line is always
/// secondary-coloured; only TaskDetail's header turns red for "Refused".
///
/// Monitor piece 13: a column is one agent CONVERSATION (a resume chain, `MonitorCore.Conversation`),
/// not one task — a resumed member inherits its parent's `group`, so before this every resume turn
/// was its own `TaskNode` group member and so its own column (an orchestrator resuming 2 agents ×
/// 8 rounds showed as 16 columns). Membership/order come from `Lineage.sections(_:).parallel.first`'s
/// `conversations` (built once per `tasksPublisher` emission); a lease is held for every member of
/// every conversation — TaskDetail's own per-member-lease pattern — and every column is rebuilt from
/// each member's freshest `useCase.task(_:)` on every recompute (F4-40), never a value cached at the
/// last `tasksPublisher` emission.
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
    @ObservationIgnored private var availabilityCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var leases: [String: any EventStreamLease] = [:]
    @ObservationIgnored private var itemsByTask: [String: [TimelineItem]] = [:]
    @ObservationIgnored private var availabilityByTask: [String: EventAvailability] = [:]
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var latestTasks: [TaskInfo] = []
    @ObservationIgnored private var latestSnapshots: [String: TaskInfo] = [:]
    @ObservationIgnored private var latestBusy: Set<String> = []
    @ObservationIgnored private var latestOutcomes: [String: String] = [:]
    /// Every task id belonging to any of this group's conversations (Monitor piece 13) — the lease
    /// diff set and cancel-all's target list. A superset of the old top-level-only `memberIDs`,
    /// since it now also names each conversation's earlier, already-terminal turns.
    @ObservationIgnored private var memberIDs: [String] = []
    /// This group's conversations as of the last `tasksPublisher` emission — membership and order
    /// only. `recompute()` always re-reads each member's own `useCase.task(_:)` before building a
    /// column (F4-40), never a `TaskInfo` cached here.
    @ObservationIgnored private var conversations: [Conversation] = []
    @ObservationIgnored private var workflowTaskIDs: [String]?
    @ObservationIgnored private var workflowFocusedTaskIDs: Set<String>?
    @ObservationIgnored private var workflowTitles: [String: String] = [:]
    
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

    /// Workflow membership comes from persisted dispatch associations, never group names. The
    /// existing Parallel feed, actions and per-member leases remain the activity implementation.
    func setWorkflowTaskIDs(_ ids: [String], focusedTaskIDs: Set<String>? = nil, titles: [String: String] = [:]) {
        workflowTaskIDs = ids
        workflowFocusedTaskIDs = focusedTaskIDs
        workflowTitles = titles
        if didSubscribe { recomputeMembersAndLeases() }
    }
    
    /// Idempotent teardown (root AGENTS.md rule 7): releases every outstanding lease, cancels every
    /// subscription, and resets `didSubscribe` so a reappearing screen (the detail pane can be
    /// revisited) subscribes and re-acquires leases fresh.
    func didDisappear() {
        cancellables.removeAll()
        itemCancellables.removeAll()
        availabilityCancellables.removeAll()
        for lease in leases.values { lease.release() }
        leases.removeAll()
        itemsByTask.removeAll()
        availabilityByTask.removeAll()
        memberIDs.removeAll()
        didSubscribe = false
    }
    
    func didTapViewPrompt() {
        showPrompt.toggle()
        recompute()
    }
    
    func didTapCancelAll() {
        guard canCancelAll else { return }
        publishDialog("Cancel every running task in this group?") {
            AlertAction(title: "Cancel all", role: .destructive) { [weak self] in
                guard let self else { return }
                // Membership is read at confirm time, not when the dialog opened: the dialog promises
                // the whole group, and a member that joined meanwhile (a new root, or a resume, which
                // `runningInSubtrees` never reaches via `spawned_by`) is part of it (PR #1 review).
                let ids = useCase.runningInSubtrees(of: memberIDs)
                Task { [useCase] in await useCase.cancelAll(ids) }
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
    
    /// Recomputes this group's conversations (Monitor piece 13 — `ParallelGroup.conversations`, one
    /// per agent) and diffs the FLATTENED member set against the currently-leased one, acquiring a
    /// lease for every newly-seen member and releasing one for every member that dropped out —
    /// TaskDetail's own `recomputeMembersAndLeases` pattern, extended across every member of every
    /// conversation rather than one task per column.
    private func recomputeMembersAndLeases() {
        let group = Lineage.sections(latestTasks).parallel.first { $0.name == groupName }
        let groupConversations: [Conversation]
        if let workflowTaskIDs {
            let byID = Dictionary(uniqueKeysWithValues: latestTasks.map { ($0.taskID, $0) })
            let associated = workflowTaskIDs.compactMap { byID[$0] }
            groupConversations = Lineage.conversations(associated).filter { conversation in
                workflowFocusedTaskIDs.map { focus in conversation.members.contains { focus.contains($0.taskID) } } ?? true
            }
        } else {
            groupConversations = group?.conversations ?? []
        }
        let newIDs = groupConversations.flatMap { $0.members.map(\.taskID) }
        let newIDSet = Set(newIDs)
        let oldIDSet = Set(memberIDs)

        for id in newIDSet.subtracting(oldIDSet) { acquireLease(id) }
        for id in oldIDSet.subtracting(newIDSet) { releaseLease(id) }
        memberIDs = newIDs
        conversations = groupConversations

        canCancelAll = group?.anyRunning == true
        isEmpty = groupConversations.isEmpty

        // Freedom/repo diversity is read from each conversation's FIRST member (its starting
        // configuration) — one entry per agent, not one per turn.
        let firstMembers = groupConversations.map(\.first)
        let freedoms = Set(firstMembers.compactMap(\.freedom).map { AccessLabel.text(freedom: $0) }).sorted().joined(separator: ", ")
        let repos = Set(firstMembers.map { Format.repoName($0.repoPath) }).sorted().joined(separator: ", ")
        let count = groupConversations.count
        headerSubtitle = "\(count) agent\(count == 1 ? "" : "s") · \(freedoms) · \(repos)"
        + (group?.startedAt.map { " · started \(Format.time($0))" } ?? "")

        recompute()
    }
    
    /// Two independent subscriptions, deliberately not combined into one: a tailer can append new
    /// items with no availability change (and vice versa) — see `TaskDetailVM.acquireMemberLease`'s
    /// identical reasoning.
    private func acquireLease(_ taskID: String) {
        guard leases[taskID] == nil else { return }
        leases[taskID] = useCase.acquireEventLease(taskID)
        itemsByTask[taskID] = useCase.items(for: taskID)
        availabilityByTask[taskID] = useCase.eventsAvailability(for: taskID)
        itemCancellables[taskID] = useCase.itemsPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                itemsByTask[taskID] = items
                recompute()
            }
        availabilityCancellables[taskID] = useCase.eventsAvailabilityPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] availability in
                guard let self else { return }
                availabilityByTask[taskID] = availability
                recompute()
            }
    }

    private func releaseLease(_ taskID: String) {
        leases[taskID]?.release()
        leases[taskID] = nil
        itemCancellables[taskID]?.cancel()
        itemCancellables[taskID] = nil
        availabilityCancellables[taskID]?.cancel()
        availabilityCancellables[taskID] = nil
        itemsByTask[taskID] = nil
        availabilityByTask[taskID] = nil
    }
    
    /// Rebuilds every column from the freshest available state — always re-reading `useCase.task(_:)`
    /// for each member rather than a `TaskInfo` cached at the last `tasksPublisher` emission, so a
    /// busy/outcome/snapshot-only update still reflects a member's current fields (F4-40). Only the
    /// membership/order skeleton (`conversations`) is held between `tasksPublisher` emissions.
    private func recompute() {
        let freshened = conversations.map { conversation in
            Conversation(members: conversation.members.map { useCase.task($0.taskID) ?? $0 })
        }
        let ordered = Lineage.parallelColumnOrder(freshened)
        columns = ordered.map(makeColumnModel)

        let footerTasks = ordered.map { latestSnapshots[$0.current.taskID] ?? $0.current }
        footerText = EnforcementText.common(footerTasks) ?? Self.fallbackFooter
    }

    /// Monitor piece 13: a column reflects a whole conversation. `task`/status pill/take-over/open
    /// all act on the CURRENT (newest) member; `title` names the conversation from its FIRST member
    /// — the same current-vs-first split `TaskDetailVM.recompute()` uses.
    private func makeColumnModel(for conversation: Conversation) -> ParallelColumnModel {
        let current = conversation.current
        let currentID = current.taskID
        let firstID = conversation.first.taskID
        let subtitle = ParallelColumnModel.subtitle(
            repoPath: current.repoPath, backend: current.backend, turns: conversation.members.count
        )

        let itemMembers = conversation.members.map {
            ConversationItemMember(task: $0, items: itemsByTask[$0.taskID] ?? [], prompt: useCase.prompt(for: $0.taskID))
        }
        let rows = ConversationTimeline.rows(itemMembers: itemMembers)
        // Monitor piece 12, Design point 4's rule, extended across every member (piece 13): a
        // shimmer only while NO member has any real content yet AND at least one member's own event
        // stream is still `.loading`; never once any member has items, and never for `.unavailable`
        // (that keeps the column's honest empty state instead).
        let isLoading = conversation.members.allSatisfy { (itemsByTask[$0.taskID] ?? []).isEmpty }
            && conversation.members.contains { (availabilityByTask[$0.taskID] ?? .loading) == .loading }

        return ParallelColumnModel(
            id: conversation.id,
            task: current,
            title: workflowTitles[currentID] ?? useCase.title(firstID),
            subtitle: subtitle,
            isBusy: latestBusy.contains(currentID),
            outcomeMessage: latestOutcomes[currentID],
            showPrompt: showPrompt,
            prompt: useCase.prompt(for: firstID),
            rows: rows,
            activityRows: ActivityRowsBuilder.build(from: rows),
            liveStep: LiveStep(rows: rows, isRunning: current.status.isRunning),
            pendingMessages: PendingMessage.visible(snapshot: latestSnapshots[currentID], events: useCase.events(for: currentID)),
            isLoading: isLoading,
            // F4-40: the snapshot only — no fallback to `task.summary`, unlike `ChangesPane`.
            summary: latestSnapshots[currentID]?.summary,
            onTapTakeover: { [weak self] in self?.didTapTakeover(taskID: currentID) },
            onTapOpenTask: { [weak self] in self?.routing.selectTask(currentID) },
            start: conversation.first.startedAt
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
                guard !refuseIfConversationMovedOn(from: taskID) else { return }
                // Dispatches synchronously into a service-owned task, then routes immediately —
                // decision 5's call path, kept exact (`ParallelView.swift:~123-127`).
                useCase.beginTakeover(taskID: taskID)
                routing.selectTask(taskID)
            }
        }
    }

    /// TaskDetail's `refuseIfConversationMovedOn`, per column (PR #1 review): if the conversation
    /// `dialogTaskID` belongs to gained a newer member while the dialog was open, confirming must not
    /// take over the stale member (it would be refused `session_busy`) nor silently retarget. The
    /// refusal is recorded on the column's current member, where the column shows it.
    private func refuseIfConversationMovedOn(from dialogTaskID: String) -> Bool {
        let conversation = conversations.first { $0.members.contains { $0.taskID == dialogTaskID } }
        let currentID = conversation?.current.taskID
        guard currentID != dialogTaskID else { return false }
        useCase.setOutcome(currentID ?? dialogTaskID, "The conversation moved on — review and try again.")
        return true
    }
}
