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
    /// writes, or either refresh runs (`AppModel.swift:291-299`; see
    /// `TaskActionRepository.resume(_:text:onResumed:)`'s doc for the exact ordering guarantee).
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

/// Navigation the task detail screen performs: moving the selection to an ancestor, a sub-task, or
/// (after a successful resume) a brand-new task.
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

/// View model for the task detail screen, ported from the app target's `TaskDetailView.swift`/
/// `TaskDetailContent`/`MessageBox` with no behaviour change.
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

    // The properties below are written from the `+Timeline`/`+Summary`/`+Actions` extension files
    // (each in its own file, per the screen shape), so they cannot be `private(set)` — `private` is
    // file-scoped in Swift. They stay non-public (no external module can write them).
    var tab: TaskTab = .timeline
    var tabs: [TaskTab] = [.timeline, .summary, .prompt, .raw]

    var timelineModel = TimelinePaneModel.empty
    var summaryModel = SummaryPaneModel.empty
    var promptText = "The prompt is recorded in the task's event log, which has not been read yet (or does not exist)."
    private(set) var rawEvents: [TaskEvent] = []
    private(set) var rawEventsPath = "/dev/null"
    private(set) var inspectorModel: InspectorModel?
    var messageBoxModel = MessageBoxModel.disabled

    // MARK: - Internal Properties (shared across extensions)

    @ObservationIgnored let useCase: any TaskDetailUseCase
    @ObservationIgnored let routing: any TaskDetailRouting
    @ObservationIgnored var cancellables = Set<AnyCancellable>()
    @ObservationIgnored var didSubscribe = false
    @ObservationIgnored var eventLease: (any EventStreamLease)?
    @ObservationIgnored var latestSnapshots: [String: TaskInfo] = [:]
    @ObservationIgnored var latestBusy: Set<String> = []
    @ObservationIgnored var latestOutcomes: [String: String] = [:]
    @ObservationIgnored var latestItems: [TimelineItem] = []
    @ObservationIgnored var latestEventsAvailability: EventAvailability = .loading

    // MARK: - Init
    
    init(taskID: String, useCase: any TaskDetailUseCase, routing: any TaskDetailRouting) {
        self.taskID = taskID
        self.useCase = useCase
        self.routing = routing
    }
    
    // MARK: - TaskDetailViewModel Methods
    
    func didAppear() {
        // The lease comes first: the repository only has a live stream for a leased task, and a
        // publisher requested before that is an empty one that never updates.
        if eventLease == nil {
            eventLease = useCase.acquireEventLease(taskID)
            rawEventsPath = useCase.eventsPath(for: taskID)
            latestItems = useCase.items(for: taskID)
            rawEvents = useCase.events(for: taskID)
            latestEventsAvailability = useCase.eventsAvailability(for: taskID)
        }
        subscribeIfNeeded()
    }

    /// Idempotent teardown (root AGENTS.md rule 7): releases the event lease, cancels every
    /// subscription, and resets `didSubscribe` so a reappearing screen subscribes again.
    func didDisappear() {
        cancellables.removeAll()
        eventLease?.release()
        eventLease = nil
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
            .sink { [weak self] _ in self?.recompute() }
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
        
        useCase.itemsPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                latestItems = items
                rawEvents = useCase.events(for: taskID)
                recompute()
            }
            .store(in: &cancellables)

        useCase.eventsAvailabilityPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] availability in
                guard let self else { return }
                latestEventsAvailability = availability
                recompute()
            }
            .store(in: &cancellables)
    }
    
    /// Rebuilds every piece of derived state from the freshest available data. Always re-reads
    /// `useCase.detail(_:)`/`useCase.task(_:)` rather than a value cached at the last emission, so a
    /// busy/outcome/snapshot-only update still reflects the task's current fields.
    func recompute() {
        task = useCase.detail(taskID)
        guard let task else {
            resetForMissingTask()
            return
        }
        
        title = useCase.title(taskID)
        let ancestors = useCase.ancestors(of: taskID)
        ancestorCrumbs = ancestors.map { AncestorCrumb(id: $0.taskID, title: useCase.title($0.taskID)) }
        
        isBusy = latestBusy.contains(taskID)
        outcomeMessage = latestOutcomes[taskID]

        takenOverBannerText = task.takenOver
        ? (task.takenOverNote ?? "This session was handed to a person in the Monitor.")
        : nil
        if !task.isRoot, let parentID = task.spawnedBy {
            let parentBackend = useCase.task(parentID)?.backend ?? "parent"
            spawnedByBannerText = "The \(parentBackend) task “\(useCase.title(parentID))” "
            + "called polybridge to start this. Its result goes back to that task when this finishes."
        } else {
            spawnedByBannerText = nil
        }
        
        canTakeover = !isBusy && task.sessionID != nil
        takeoverButtonLabel = task.status.isRunning ? "Take over" : "Continue in terminal"
        takeoverHelp = task.sessionID == nil
        ? "The task has not reported a session yet."
        : "Stop the headless run and resume the session interactively."
        if let parent = task.spawnedBy, useCase.task(parent) != nil {
            openParentTaskID = parent
        } else {
            openParentTaskID = nil
        }
        canCancel = task.status.isRunning

        // Read from the snapshot explicitly, not `task` (which came from `detail(_:)` and can
        // briefly be the brief listing when statuses disagree — that shape has no `resume_command`
        // at all).
        resumeCommand = useCase.snapshot(taskID)?.resumeCommand
        copyResumeCommandHelp = task.status.isRunning
        ? "Copies a command that resumes this session in your own terminal. This task is still "
        + "running — resuming it now puts two writers on one conversation; prefer Take over."
        : "Copies a command that resumes this session in your own terminal."

        recomputeTimeline(task: task)
        recomputeInspector(task: task, ancestors: ancestors)
        recomputeMessageBox(task: task)
        recomputeSummary(task: task)
    }

    /// "Now" (the current running tool), lineage, and the raw-snapshot "Details"/enforcement.
    /// Assembled here (not a dedicated `+Inspector` extension) because it aggregates data the other
    /// extensions already computed (timeline `latestItems`) plus core lineage.
    func recomputeInspector(task: TaskInfo, ancestors: [TaskInfo]) {
        let siblings = useCase.siblings(of: taskID)
        let snapshot = useCase.snapshot(taskID)
        inspectorModel = InspectorModel(
            task: task,
            current: useCase.current(for: taskID),
            stepCount: latestItems.count,
            activity: useCase.activity(for: taskID),
            subtaskCount: useCase.children(of: taskID).count,
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
        inspectorModel = nil
    }
}
