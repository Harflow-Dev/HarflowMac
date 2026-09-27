//
//  TaskDetailVM.swift
//  MainWindowFeature
//

import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUtilities

// MARK: - TaskDetailUseCase

/// The task detail screen's data needs over `TaskListRepository`, `TaskSnapshotRepository`,
/// `TaskActionRepository`, `EventStreamRepository`, `TakeoverService` and `ToolEnvironmentRepository`.
@Mockable
@MainActor
protocol TaskDetailUseCase: Sendable {
    
    // Listing / lineage
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func hasListedPublisher() -> AnyPublisher<Bool, Never>
    func titlesPublisher() -> AnyPublisher<[String: String], Never>
    /// The fullest view of the task (`TaskListRepository.detail(_:)`'s precedence).
    func detail(_ id: String) -> TaskInfo?
    func task(_ id: String) -> TaskInfo?
    func title(_ id: String) -> String
    func ancestors(of id: String) -> [TaskInfo]
    func children(of id: String) -> [TaskInfo]
    func siblings(of id: String) -> [TaskInfo]
    /// The whole conversation `id` belongs to (any member resolves it — Monitor piece 7, settled
    /// Design point 6), oldest to newest. A task with no follow-up is its own single-member
    /// conversation; a task absent from the listing resolves to `[]`.
    func conversationMembers(of id: String) -> [TaskInfo]
    /// The real cancel scope for `id` (Review round 1 item 5 / round 2): `id` itself, every
    /// descendant reachable by following `spawned_by`, and every task whose `root_task_id` names it
    /// directly — matches `tasks.py`'s cancel cascade exactly (`MonitorCore.Lineage.cancelScope(of:in:)`).
    func cancelScope(of id: String) -> Set<String>
    /// The deterministic survivor rule for "retention while open" (Review round 1 item 4 / Codex
    /// review round 1, finding 3): the oldest still-present member of `candidates`
    /// (`MonitorCore.Lineage.oldestSurvivor(among:in:)`) — the SAME rule `SidebarVM` uses, so a
    /// branching prune resolves to the same id on both screens.
    func oldestSurvivor(among candidates: Set<String>) -> String?

    // Snapshot
    func snapshot(_ id: String) -> TaskInfo?
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never>
    func refreshSnapshot(_ id: String) async
    
    // Busy / outcome
    func busyPublisher() -> AnyPublisher<Set<String>, Never>
    func outcomesPublisher() -> AnyPublisher<[String: String], Never>
    
    // Actions
    @discardableResult func cancel(_ id: String) async throws -> Bool
    @discardableResult func send(_ id: String, text: String) async throws -> Bool
    /// `onResumed` fires right after the new task id comes back — before busy releases, the outcome
    /// writes, or either refresh runs (see `TaskActionRepository.resume(_:text:onResumed:)`'s doc
    /// for the exact ordering guarantee). Continue no longer navigates on success (Monitor piece 7,
    /// Design point 7), so `submitMessage(_:)` passes a no-op closure here.
    @discardableResult func resume(_ id: String, text: String, onResumed: @escaping @Sendable (String) async -> Void) async throws -> String?
    func beginTakeover(taskID: String)
    /// Records a durable outcome line for `id` through `TaskActionRepository.setOutcome` (Monitor
    /// piece 3/3's "Copy resume command") — the same channel Cancel/Send/Resume use, so the line
    /// survives a recompute or a leave/revisit, unlike writing the VM's `outcomeMessage` directly.
    func setOutcome(_ id: String, _ text: String?)

    // Events (decision 6)
    func acquireEventLease(_ id: String) -> any EventStreamLease
    func events(for id: String) -> [TaskEvent]
    func eventsPublisher(for id: String) -> AnyPublisher<[TaskEvent], Never>
    func items(for id: String) -> [TimelineItem]
    func itemsPublisher(for id: String) -> AnyPublisher<[TimelineItem], Never>
    /// Threaded through so the Summary tab's "Files the agent edited" section can tell "nothing has
    /// happened yet" apart from "there is no log to read at all" — an empty `events(for:)` cannot.
    func eventsAvailability(for id: String) -> EventAvailability
    func eventsAvailabilityPublisher(for id: String) -> AnyPublisher<EventAvailability, Never>
    func activity(for id: String) -> ActivityCounts
    func current(for id: String) -> TimelineItem?
    func prompt(for id: String) -> String?
    func eventsPath(for id: String) -> String
}

// MARK: - TaskDetailRouting

/// Navigation the task detail screen performs: moving the selection to an ancestor or a sub-task.
/// A successful `resume` (Continue) does **not** navigate any more (Monitor piece 7): the
/// conversation stays selected, and the new turn appears under it once the listing refreshes.
@Mockable
@MainActor
protocol TaskDetailRouting: Sendable {
    func selectTask(_ taskID: String)
    /// Writes `text` to the system pasteboard (Monitor piece 3/3's "Copy resume command"),
    /// returning whether the write succeeded. AppKit lives in the coordinator, never the VM — see
    /// `MainWindowCoordinator.chooseDirectory()` for the same pattern.
    func copyToPasteboard(_ text: String) -> Bool
}

// MARK: - TaskDetailVM

/// View model for the task detail screen. `taskID` may be ANY member of a conversation (a resume
/// chain, Monitor piece 7) — `didAppear()`/`recompute()` always resolve the whole conversation from
/// it (settled Design point 6) and every derived property below reflects the conversation's
/// **current** (newest) member unless documented otherwise; only `title`/breadcrumbs/lineage come
/// from its **first** member, which names and places the conversation in the sidebar's tree.
@Observable
@MainActor
final class TaskDetailVM: TaskDetailViewModel {

    // MARK: - TaskDetailViewModel Properties

    let taskID: String
    private(set) var task: TaskInfo?
    private(set) var hasListed = false

    private(set) var title = ""
    private(set) var ancestorCrumbs: [AncestorCrumb] = []
    private(set) var isBusy = false
    private(set) var outcomeMessage: String?
    private(set) var takenOverBannerText: String?
    private(set) var spawnedByBannerText: String?
    private(set) var canTakeover = false
    private(set) var takeoverButtonLabel = "Take over"
    private(set) var takeoverHelp = ""
    private(set) var openParentTaskID: String?
    private(set) var canCancel = false
    private(set) var resumeCommand: String?
    private(set) var copyResumeCommandHelp = ""
    /// "N turns", shown next to the title once the conversation has more than one member — `nil`
    /// for a plain, never-followed-up task (settled Design point 6).
    private(set) var turnsText: String?

    // The properties below are written from the `+Timeline`/`+Summary`/`+Actions` extension files
    // (each in its own file, per the screen shape), so they cannot be `private(set)` — `private` is
    // file-scoped in Swift. They stay non-public (no external module can write them).
    var tab: TaskTab = .timeline
    var tabs: [TaskTab] = [.timeline, .summary, .prompt, .raw]

    var timelineModel = TimelinePaneModel.empty
    var summaryModel = SummaryPaneModel.empty
    var promptText = "The prompt is recorded in the task's event log, which has not been read yet (or does not exist)."
    var rawEvents: [TaskEvent] = []
    var rawEventsPath = "/dev/null"
    private(set) var inspectorModel: InspectorModel?
    var messageBoxModel = MessageBoxModel.disabled

    // MARK: - Internal Properties (shared across extensions)

    @ObservationIgnored let useCase: any TaskDetailUseCase
    @ObservationIgnored let routing: any TaskDetailRouting
    @ObservationIgnored var cancellables = Set<AnyCancellable>()
    @ObservationIgnored var didSubscribe = false
    /// The conversation's own members, oldest to newest — resolved from `taskID` (any member) on
    /// every membership change. Never empty once the task is known at all.
    @ObservationIgnored var conversationMembers: [TaskInfo] = []
    /// The id every action (send/cancel/take over/copy resume command/continue) targets — the
    /// conversation's newest member, kept in sync with `conversationMembers` by `recompute()`.
    @ObservationIgnored private(set) var currentTaskID: String
    /// One event lease per conversation member (Parallel's own pattern — decision 6), acquired as
    /// members appear and released as they drop out, so a follow-up's own turn tails from the
    /// moment it exists.
    @ObservationIgnored var leases: [String: any EventStreamLease] = [:]
    @ObservationIgnored var memberCancellables: [String: [AnyCancellable]] = [:]
    @ObservationIgnored var eventsByMember: [String: [TaskEvent]] = [:]
    @ObservationIgnored var eventsAvailabilityByMember: [String: EventAvailability] = [:]
    @ObservationIgnored var latestSnapshots: [String: TaskInfo] = [:]
    @ObservationIgnored var latestBusy: Set<String> = []
    @ObservationIgnored var latestOutcomes: [String: String] = [:]
    /// The conversation's own member ids, oldest to newest, as of the last time it was resolved
    /// directly from `identityTaskID` (Review round 1, item 4 — "retention while open"). Never
    /// cleared on an ordinary recompute; only replaced wholesale by a fresh direct resolution. Read
    /// when a later resolution comes back empty (`identityTaskID`'s own record was pruned by
    /// retention) to find a still-present member and hand off to the conversation it now identifies,
    /// instead of reporting the whole conversation gone.
    @ObservationIgnored private var lastKnownMemberIDsOldestFirst: [String] = []
    /// The id `recomputeMembersAndLeases()` resolves the conversation FROM — the conversation's own
    /// normalised first (oldest) member id, tracked the same way the sidebar's own row id is
    /// (Codex review round 2, finding 2), never pinned to `taskID` (the member this VM happened to
    /// be opened through). Starts as `taskID`, but every successful resolution re-derives it from
    /// `members[0].taskID` — so a VM opened through a LATER member (e.g. "C" in a branching
    /// A→B, A→C) still tracks the conversation by "A"'s id once resolved, and hands off through the
    /// shared, deterministic `oldestSurvivor` rule when "A" is later pruned, landing on the SAME
    /// surviving member the sidebar does — rather than falling back on `taskID`'s own, now-orphaned
    /// singleton conversation (which is what querying `conversationMembers(of: taskID)` forever
    /// would do: "C" alone is still a valid, non-empty conversation once "A" is gone, so the old
    /// code's `members.isEmpty` retention check never even triggered for it).
    @ObservationIgnored private var identityTaskID: String

    // MARK: - Init

    init(taskID: String, useCase: any TaskDetailUseCase, routing: any TaskDetailRouting) {
        self.taskID = taskID
        self.currentTaskID = taskID
        self.identityTaskID = taskID
        self.useCase = useCase
        self.routing = routing
    }

    // MARK: - TaskDetailViewModel Methods

    func didAppear() {
        // Members (and so leases) come first: the repository only has a live stream for a leased
        // task, and a publisher requested before that is an empty one that never updates.
        recomputeMembersAndLeases()
        subscribeIfNeeded()
    }

    /// Idempotent teardown (root AGENTS.md rule 7): releases every member's event lease, cancels
    /// every subscription, and resets `didSubscribe` so a reappearing screen subscribes and
    /// re-acquires leases fresh.
    func didDisappear() {
        cancellables.removeAll()
        memberCancellables.removeAll()
        for lease in leases.values { lease.release() }
        leases.removeAll()
        eventsByMember.removeAll()
        eventsAvailabilityByMember.removeAll()
        conversationMembers = []
        didSubscribe = false
    }

    func didSelectTab(_ tab: TaskTab) {
        self.tab = tab
    }

    func didTapTask(_ taskID: String) {
        routing.selectTask(taskID)
    }

    // MARK: - Internal Methods

    func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true

        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recomputeMembersAndLeases() }
            .store(in: &cancellables)

        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                guard let self else { return }
                hasListed = value
                recompute()
            }
            .store(in: &cancellables)

        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
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
    }

    /// Recomputes conversation membership (Design point 6) from `identityTaskID` — the conversation's
    /// own normalised identity, NOT the fixed `taskID` this VM was opened through (Codex review
    /// round 2, finding 2) — diffs it against the currently-leased member set — acquiring a lease
    /// for every newly-seen member and releasing one for every member that dropped out (retention) —
    /// then recomputes everything else. Called on `didAppear()` and every later listing change,
    /// since a follow-up (Continue) introduces a brand new member the VM must start tailing
    /// immediately.
    ///
    /// Retention while open (Review round 1, item 4): when `identityTaskID` itself no longer
    /// resolves (its own record was pruned), this falls back to the oldest still-present member
    /// remembered from the last successful resolution (`Lineage.oldestSurvivor(among:in:)`, via
    /// `useCase.oldestSurvivor(among:)` — Codex review round 1, finding 3's shared, deterministic
    /// rule) and re-resolves THROUGH it — so an open conversation whose first member ages out keeps
    /// showing as the live conversation it still is, via its surviving member, rather than
    /// reporting the whole thing as gone. Every successful resolution then re-derives
    /// `identityTaskID` from the resolved conversation's own first member, so this keeps tracking
    /// the SAME conversation the sidebar does, even when it was opened through a later member.
    func recomputeMembersAndLeases() {
        var members = useCase.conversationMembers(of: identityTaskID)
        if members.isEmpty, let survivor = useCase.oldestSurvivor(among: Set(lastKnownMemberIDsOldestFirst)) {
            members = useCase.conversationMembers(of: survivor)
        }
        if !members.isEmpty {
            lastKnownMemberIDsOldestFirst = members.map(\.taskID)
            identityTaskID = members[0].taskID
        }
        conversationMembers = members
        let newIDs = Set(members.map(\.taskID))
        let oldIDs = Set(leases.keys)
        for id in newIDs.subtracting(oldIDs) { acquireMemberLease(id) }
        for id in oldIDs.subtracting(newIDs) { releaseMemberLease(id) }
        recompute()
    }

    /// Two INDEPENDENT subscriptions, deliberately not a `CombineLatest` of the two publishers: a
    /// tailer can append new items with no availability change (and vice versa), and
    /// `CombineLatest` would otherwise wait for both to have emitted at least once before ever
    /// firing, silently dropping the first update whichever publisher fires alone.
    private func acquireMemberLease(_ id: String) {
        guard leases[id] == nil else { return }
        leases[id] = useCase.acquireEventLease(id)
        eventsByMember[id] = useCase.events(for: id)
        eventsAvailabilityByMember[id] = useCase.eventsAvailability(for: id)
        var subscriptions: [AnyCancellable] = []
        subscriptions.append(
            useCase.itemsPublisher(for: id)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self else { return }
                    eventsByMember[id] = useCase.events(for: id)
                    recompute()
                }
        )
        subscriptions.append(
            useCase.eventsAvailabilityPublisher(for: id)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] availability in
                    guard let self else { return }
                    eventsAvailabilityByMember[id] = availability
                    recompute()
                }
        )
        memberCancellables[id] = subscriptions
    }

    private func releaseMemberLease(_ id: String) {
        leases[id]?.release()
        leases[id] = nil
        memberCancellables[id] = nil
        eventsByMember[id] = nil
        eventsAvailabilityByMember[id] = nil
    }

    /// Rebuilds every piece of derived state from the freshest available data. Always re-reads
    /// `useCase.detail(_:)`/`useCase.task(_:)` rather than a value cached at the last emission, so a
    /// busy/outcome/snapshot-only update still reflects the task's current fields. Status,
    /// placement, age and every action target the conversation's **current** (newest) member; only
    /// the title and lineage come from its **first**.
    func recompute() {
        guard let currentMember = conversationMembers.last, let detail = useCase.detail(currentMember.taskID) else {
            task = nil
            resetForMissingTask()
            return
        }
        task = detail
        currentTaskID = detail.taskID
        let firstMember = conversationMembers[0]
        turnsText = conversationMembers.count > 1 ? "\(conversationMembers.count) turns" : nil

        title = useCase.title(firstMember.taskID)
        // The conversation's OWN placement in the sidebar's tree (breadcrumbs) — always the FIRST
        // member's spawned_by chain (Design point 2), never the current member's.
        let placementAncestors = useCase.ancestors(of: firstMember.taskID)
        ancestorCrumbs = placementAncestors.map { AncestorCrumb(id: $0.taskID, title: useCase.title($0.taskID)) }
        // The CURRENT task's own spawned_by chain — deliberately a SEPARATE computation from the
        // one above (Codex review round 1, finding 4): an ancestor of the conversation's first
        // member does not necessarily reach the CURRENT member's own cancel scope (e.g. P spawned
        // A; an unrelated Q later resumed A as B — cancelling P never reaches B). The Inspector's
        // own "Lineage" list and "Cancelling the parent also tries to stop this task" copy must
        // describe a relationship that is actually true of the task on screen, so it is built from
        // `currentTaskID`'s own ancestors — which, being an ordinary spawned_by chain, always DOES
        // satisfy cancel-scope reachability to the current task.
        let currentTaskAncestors = useCase.ancestors(of: currentTaskID)

        isBusy = latestBusy.contains(currentTaskID)
        outcomeMessage = latestOutcomes[currentTaskID]

        takenOverBannerText = detail.takenOver
        ? (detail.takenOverNote ?? "This session was handed to a person in the Monitor.")
        : nil
        if !firstMember.isRoot, let parentID = firstMember.spawnedBy {
            let parentBackend = useCase.task(parentID)?.backend ?? "parent"
            spawnedByBannerText = "The \(parentBackend) task “\(useCase.title(parentID))” "
            + "called polybridge to start this. Its result goes back to that task when this finishes."
        } else {
            spawnedByBannerText = nil
        }

        canTakeover = !isBusy && detail.sessionID != nil
        takeoverButtonLabel = detail.status.isRunning ? "Take over" : "Continue in terminal"
        takeoverHelp = detail.sessionID == nil
        ? "The task has not reported a session yet."
        : "Stop the headless run and resume the session interactively."
        if let parent = firstMember.spawnedBy, useCase.task(parent) != nil {
            openParentTaskID = parent
        } else {
            openParentTaskID = nil
        }
        canCancel = detail.status.isRunning

        // Read from the snapshot explicitly, not `detail` (which came from `detail(_:)` and can
        // briefly be the brief listing when statuses disagree — that shape has no `resume_command`
        // at all).
        resumeCommand = useCase.snapshot(currentTaskID)?.resumeCommand
        copyResumeCommandHelp = detail.status.isRunning
        ? "Copies a command that resumes this session in your own terminal. This task is still "
        + "running — resuming it now puts two writers on one conversation; prefer Take over."
        : "Copies a command that resumes this session in your own terminal."

        recomputeTimeline(task: detail)
        recomputeInspector(task: detail, ancestors: currentTaskAncestors)
        recomputeMessageBox(task: detail)
        recomputeSummary(task: detail)
    }

    /// Every child any conversation member has started via `spawned_by` (Design point 3) — shared by
    /// the Timeline's sub-task strip (`+Timeline.swift`) and the cancel dialog's "not cancelled by
    /// this" listing (`+Actions.swift`'s `didTapCancel()`).
    func allConversationChildren() -> [TaskInfo] {
        conversationMembers.flatMap { useCase.children(of: $0.taskID) }
    }

    /// "Now" (the current running tool), lineage, and the raw-snapshot "Details"/enforcement.
    /// Assembled here (not a dedicated `+Inspector` extension) because it aggregates data the other
    /// extensions already computed plus core lineage. Activity and sub-task count are summed across
    /// every conversation member (Design point 3: "children of any member hang under the
    /// conversation's node"); "Now" reads the current member alone, since only it can be running.
    /// `ancestors` and `siblings` are both about the CURRENT task's own position (Codex review
    /// round 1, finding 4) — never the conversation's first member, whose own ancestors do not
    /// necessarily reach the current task at all.
    func recomputeInspector(task: TaskInfo, ancestors: [TaskInfo]) {
        let siblings = useCase.siblings(of: currentTaskID)
        let snapshot = useCase.snapshot(currentTaskID)
        let activity = conversationMembers.reduce(ActivityCounts()) { acc, member in
            let memberActivity = useCase.activity(for: member.taskID)
            var result = acc
            result.toolCalls += memberActivity.toolCalls
            result.edits += memberActivity.edits
            result.commands += memberActivity.commands
            return result
        }
        let subtaskCount = conversationMembers.reduce(0) { $0 + useCase.children(of: $1.taskID).count }
        inspectorModel = InspectorModel(
            task: task,
            current: useCase.current(for: currentTaskID),
            stepCount: timelineModel.rows.filter { if case .item = $0.kind { return true }; return false }.count,
            activity: activity,
            subtaskCount: subtaskCount,
            ancestors: ancestors.map { SubTaskEntry(task: $0, title: useCase.title($0.taskID)) },
            siblings: siblings.map { SubTaskEntry(task: $0, title: useCase.title($0.taskID)) },
            detail: snapshot ?? task,
            hasSnapshot: snapshot != nil,
            notices: task.notices,
            onSelectTask: { [weak self] id in self?.didTapTask(id) }
        )
    }

    private func resetForMissingTask() {
        title = ""
        ancestorCrumbs = []
        isBusy = false
        outcomeMessage = nil
        takenOverBannerText = nil
        spawnedByBannerText = nil
        canTakeover = false
        openParentTaskID = nil
        canCancel = false
        resumeCommand = nil
        copyResumeCommandHelp = ""
        turnsText = nil
        inspectorModel = nil
        timelineModel = .empty
        summaryModel = .empty
    }
}
