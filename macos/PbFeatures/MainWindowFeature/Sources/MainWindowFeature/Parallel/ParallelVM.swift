import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import PbUtilities

// MARK: - ParallelUseCase

/// Data and action boundary for Parallel conversation presentation.
@Mockable
@MainActor
protocol ParallelUseCase: Sendable {

    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never>
    func busyPublisher() -> AnyPublisher<Set<String>, Never>
    func outcomesPublisher() -> AnyPublisher<[String: String], Never>
    func titlesPublisher() -> AnyPublisher<[String: String], Never>

    /// Returns the fresh listing entry.
    func task(_ id: String) -> TaskInfo?
    func title(_ taskID: String) -> String

    func acquireEventLease(_ taskID: String) -> any EventStreamLease
    func events(for taskID: String) -> [TaskEvent]
    func items(for taskID: String) -> [TimelineItem]
    func itemsPublisher(for taskID: String) -> AnyPublisher<[TimelineItem], Never>
    func prompt(for taskID: String) -> String?
    func eventHistory(for taskID: String) -> EventHistoryState
    func eventHistoryPublisher(for taskID: String) -> AnyPublisher<EventHistoryState, Never>
    func conversationHistory(sessionID: String, cursor: String?) async throws -> TaskHistoryPage?
    @discardableResult func loadMoreEvents(_ taskID: String) -> Bool
    /// Distinguishes pending activity from a missing or unreadable log.
    func eventsAvailability(for taskID: String) -> EventAvailability
    func eventsAvailabilityPublisher(for taskID: String) -> AnyPublisher<EventAvailability, Never>

    func runningInSubtrees(of ids: [String]) -> [String]
    func cancelAll(_ ids: [String]) async
    func setOutcome(_ id: String, _ text: String?)

    /// Starts Terminal takeover synchronously before routing.
    func beginTakeover(taskID: String)
}

extension ParallelUseCase {
    func eventHistory(for _: String) -> EventHistoryState { EventHistoryState() }
    func eventHistoryPublisher(for id: String) -> AnyPublisher<EventHistoryState, Never> { Just(eventHistory(for: id)).eraseToAnyPublisher() }
    @discardableResult func loadMoreEvents(_: String) -> Bool { false }
    func conversationHistory(sessionID _: String, cursor _: String?) async throws -> TaskHistoryPage? { nil }
}

@MainActor
protocol ParallelActivityReadiness {
    func activityReadyPublisher() -> AnyPublisher<Bool, Never>
}

// MARK: - ParallelRouting

@Mockable
@MainActor
protocol ParallelRouting: Sendable {
    func selectTask(_ taskID: String)
}

// MARK: - ParallelVM

/// Presents complete conversation membership with bounded resident activity leases.
/// Immutable value inputs build off-main; complete equality guards UI publication.
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
    @ObservationIgnored private let buildColumns: ParallelColumnsBuild
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var itemCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var availabilityCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var leaseGenerations: [String: UUID] = [:]
    @ObservationIgnored private var ownerByMember: [String: String] = [:]
    @ObservationIgnored private var conversationByID: [String: Conversation] = [:]
    @ObservationIgnored private var leases: [String: any EventStreamLease] = [:]
    @ObservationIgnored private var itemsByTask: [String: [TimelineItem]] = [:]
    @ObservationIgnored private var availabilityByTask: [String: EventAvailability] = [:]
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var latestTasks: [TaskInfo] = []
    @ObservationIgnored private var latestSnapshots: [String: TaskInfo] = [:]
    @ObservationIgnored private var latestBusy: Set<String> = []
    @ObservationIgnored private var latestOutcomes: [String: String] = [:]
    @ObservationIgnored private var memberIDs: [String] = []
    @ObservationIgnored private var conversations: [Conversation] = []
    @ObservationIgnored private var workflowTaskIDs: [String]?
    @ObservationIgnored private var workflowFocusedTaskIDs: Set<String>?
    @ObservationIgnored private var workflowTitles: [String: String] = [:]
    @ObservationIgnored private var initialMembershipResolved = false
    @ObservationIgnored private var activityReady = false
    @ObservationIgnored private var arrivalTracker = PanelArrivalTracker()
    @ObservationIgnored private var viewportOffset: CGFloat = 0
    @ObservationIgnored private var viewportWidth: CGFloat = 0
    @ObservationIgnored private var residentIDs: Set<String> = []
    @ObservationIgnored private var refreshingRetainedIDs: Set<String> = []
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var neededMemberIDs: Set<String> = []
    @ObservationIgnored private lazy var history = ParallelActivityHistory(useCase: useCase,
        onInventory: { [weak self] in self?.recomputeMembersAndLeases() },
        onChange: { [weak self] memberID in self?.historyDidChange(memberID) })

    @ObservationIgnored private lazy var acquisition = ParallelLeaseAcquisition(acquire: { [weak self] id in
        guard let self, didSubscribe, neededMemberIDs.contains(id), leases[id] == nil else { return false }
        acquireLease(id)
        return true
    }, onBurst: { [weak self] ids, start in self?.didAcquire(ids, start: start) }, onFinish: { [weak self] in
        guard let self else { return }
        history.update(conversations: orderedConversations, visible: visibleIDs, states: uiStates)
    })
    @ObservationIgnored private var uiStates: [String: ParallelColumnUIState] = [:]
    @ObservationIgnored private var descriptors: [String: ParallelColumnPresentation] = [:]
    @ObservationIgnored private var presentations: [String: ParallelColumnPresentation] = [:]
    @ObservationIgnored private var completedInputs: [String: ParallelColumnInput] = [:]
    @ObservationIgnored private var desiredInputs: [String: ParallelColumnInput] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pendingInputs: [String: ParallelColumnInput]?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var epoch: UInt64 = 0
    @ObservationIgnored private var scheduledStart: UInt64?
    @ObservationIgnored private var latencyStart: UInt64?
    var isPresentationSettled: Bool { worker == nil && pendingInputs == nil && acquisition.isSettled }
    var leasedMemberCount: Int { leases.count }
    var residentColumnCount: Int { residentIDs.count }
    var retainedColumnStateCount: Int { uiStates.count }
    @ObservationIgnored private var orderedConversations: [Conversation] = []
    @ObservationIgnored private var arrivals: Set<String> = []
    @ObservationIgnored private(set) var presentationWriteCount = 0
    @ObservationIgnored private(set) var builtColumnCount = 0
    @ObservationIgnored private(set) var sourceUpdateCount = 0

    func columnState(for id: String) -> ParallelColumnUIState {
        if let state = uiStates[id] { return state }
        let state = ParallelColumnUIState()
        if conversationByID[id] != nil { uiStates[id] = state }
        return state
    }

    func updateViewport(offset: CGFloat, width: CGFloat) {
        guard viewportOffset != offset || viewportWidth != width else { return }
        let start = MonitorMetrics.begin()
        defer { MonitorMetrics.end(start, stage: .parallelViewport, residentColumns: residentIDs.count, leasedMembers: leases.count) }
        viewportOffset = offset
        viewportWidth = width
        guard didSubscribe else { return }
        let stride = ParallelLayout.columnWidth(memberCount: orderedConversations.count, availableWidth: width)
            + ParallelLayout.dividerWidth
        let shown = ParallelResidency.visibleIndices(count: orderedConversations.count, offset: offset, width: width, stride: stride)
        let nextVisible = Set(shown.map { orderedConversations[$0].id })
        guard nextVisible != visibleIDs else { return }
        let inputs = updateResidency()
        publishColumns()
        schedule(inputs)
    }
    
    // MARK: - Init
    
    init(groupName: String, useCase: any ParallelUseCase, routing: any ParallelRouting,
         buildColumns: @escaping ParallelColumnsBuild = ParallelPresentationBuilder.buildColumns) {
        self.groupName = groupName
        self.useCase = useCase
        self.routing = routing
        self.buildColumns = buildColumns
    }
    
    // MARK: - ParallelViewModel Methods
    
    func didAppear() {
        subscribeIfNeeded()
    }

    /// Workflow membership follows persisted dispatch associations.
    func setWorkflowTaskIDs(_ ids: [String], focusedTaskIDs: Set<String>? = nil, titles: [String: String] = [:]) {
        workflowTaskIDs = ids
        workflowFocusedTaskIDs = focusedTaskIDs
        workflowTitles = titles
        if didSubscribe { recomputeMembersAndLeases() }
    }
    
    func didDisappear() {
        epoch &+= 1
        revision &+= 1
        worker?.cancel()
        acquisition.cancel()
        neededMemberIDs.removeAll()
        history.teardown()
        pendingInputs = nil
        desiredInputs.removeAll()
        completedInputs.removeAll()
        presentations.removeAll()
        descriptors.removeAll()
        residentIDs.removeAll()
        refreshingRetainedIDs.removeAll()
        visibleIDs.removeAll()
        uiStates.removeAll()
        orderedConversations.removeAll()
        viewportWidth = 0
        columns.removeAll()
        cancellables.removeAll()
        itemCancellables.removeAll()
        availabilityCancellables.removeAll()
        for lease in leases.values { lease.release() }
        leases.removeAll()
        leaseGenerations.removeAll()
        ownerByMember.removeAll()
        conversationByID.removeAll()
        itemsByTask.removeAll()
        availabilityByTask.removeAll()
        memberIDs.removeAll()
        didSubscribe = false
        activityReady = false
        initialMembershipResolved = false
        arrivalTracker = PanelArrivalTracker()
    }
    
    func didTapViewPrompt() {
        let start = MonitorMetrics.begin()
        showPrompt.toggle()
        for id in descriptors.keys { descriptors[id]?.showPrompt = showPrompt }
        var inputs = desiredInputs
        for id in inputs.keys { inputs[id]?.base.showPrompt = showPrompt }
        publishColumns()
        schedule(inputs)
        MonitorMetrics.end(start, stage: .parallelPreparation,
            residentColumns: residentIDs.count, leasedMembers: leases.count)
    }
    
    func didTapCancelAll() {
        guard canCancelAll else { return }
        publishDialog("Cancel every running task in this group?") {
            AlertAction(title: "Cancel all", role: .destructive) { [weak self] in
                guard let self else { return }
                // Resolve membership at confirmation so newly resumed tasks are included.
                let ids = useCase.runningInSubtrees(of: memberIDs)
                Task { [useCase] in await useCase.cancelAll(ids) }
            }
        }
    }
    
    // MARK: - Private Methods
    
    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        let subscriptionEpoch = epoch
        if let readiness = useCase as? any ParallelActivityReadiness {
            readiness.activityReadyPublisher()
.receive(on: DispatchQueue.main)
.sink { [weak self] ready in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                activityReady = ready
                recompute()
            }
.store(in: &cancellables)
        } else { activityReady = true }
        
        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                sourceUpdateCount += 1
                guard !initialMembershipResolved || latestTasks != tasks else { return }
                initialMembershipResolved = true
                latestTasks = tasks
                recomputeMembersAndLeases()
            }
            .store(in: &cancellables)
        
        useCase.snapshotsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshots in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                latestSnapshots = snapshots
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.busyPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] busy in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                latestBusy = busy
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.outcomesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] outcomes in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                latestOutcomes = outcomes
                recompute()
            }
            .store(in: &cancellables)
        
        // Titles load independently of the listing (Codex review finding): a column must refresh
        // when it changes on its own, not only when an unrelated publisher happens to fire afterward.
        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, didSubscribe, epoch == subscriptionEpoch else { return }
                recompute()
            }
            .store(in: &cancellables)
    }
    
    /// Resolves membership before viewport residency.
    private func recomputeMembersAndLeases() {
        let preparation = MonitorMetrics.begin()
        let group = Lineage.sections(latestTasks).parallel.first { $0.name == groupName }
        let groupConversations = ParallelMembership.conversations(tasks: latestTasks, group: group?.conversations ?? [],
            workflowTaskIDs: workflowTaskIDs, focusedTaskIDs: workflowFocusedTaskIDs)
.map { ParallelMembership.extending($0, states: uiStates) }
        let newIDs = groupConversations.flatMap { $0.members.map(\.taskID) }
        memberIDs = newIDs
        let migration = ParallelStateMigration.mapping(previous: conversations, current: groupConversations,
            retained: Set(uiStates.keys).union(presentations.keys).union(completedInputs.keys))
        uiStates = migration.compactMapValues { uiStates[$0] }
        presentations = migration.reduce(into: [:]) { result, entry in
            guard var presentation = presentations[entry.value] else { return }
            presentation.id = entry.key
            result[entry.key] = presentation
        }
        completedInputs = migration.reduce(into: [:]) { result, entry in
            guard var input = completedInputs[entry.value] else { return }
            input.base.id = entry.key
            result[entry.key] = input
        }
        conversations = groupConversations

        let cancellable = group?.anyRunning == true
        if canCancelAll != cancellable { canCancelAll = cancellable }
        let empty = groupConversations.isEmpty
        if isEmpty != empty { isEmpty = empty }

        let subtitle = ParallelHeader.subtitle(groupConversations, startedAt: group?.startedAt)
        if headerSubtitle != subtitle { headerSubtitle = subtitle }

        MonitorMetrics.end(preparation, stage: .parallelPreparation, residentColumns: residentIDs.count, leasedMembers: leases.count)
        recompute()
    }
    
    /// Items and availability change independently, so each keeps its own subscription.
    private func acquireLease(_ taskID: String) {
        guard leases[taskID] == nil else { return }
        let generation = UUID()
        leaseGenerations[taskID] = generation
        leases[taskID] = useCase.acquireEventLease(taskID)
        if let owner = ownerByMember[taskID] { history.acquire(taskID, conversationID: owner, state: columnState(for: owner)) }
        itemsByTask[taskID] = useCase.items(for: taskID)
        availabilityByTask[taskID] = useCase.eventsAvailability(for: taskID)
        itemCancellables[taskID] = useCase.itemsPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                guard leaseGenerations[taskID] == generation, itemsByTask[taskID] != items else { return }
                itemsByTask[taskID] = items
                history.changedItems(taskID)
                refreshActivity(memberID: taskID)
            }
        availabilityCancellables[taskID] = useCase.eventsAvailabilityPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] availability in
                guard let self else { return }
                guard leaseGenerations[taskID] == generation, availabilityByTask[taskID] != availability else { return }
                availabilityByTask[taskID] = availability
                history.changedItems(taskID)
                refreshActivity(memberID: taskID)
            }
    }

    private func releaseLease(_ taskID: String) {
        history.release(taskID)
        leases[taskID]?.release()
        leases[taskID] = nil
        leaseGenerations[taskID] = nil
        itemCancellables[taskID]?.cancel()
        itemCancellables[taskID] = nil
        availabilityCancellables[taskID]?.cancel()
        availabilityCancellables[taskID] = nil
        itemsByTask[taskID] = nil
        availabilityByTask[taskID] = nil
    }
    
    /// Refresh metadata, retaining the ownership skeleton for activity and viewport updates.
    private func recompute() {
        let preparationStart = MonitorMetrics.begin()
        defer { MonitorMetrics.end(preparationStart, stage: .parallelPreparation, residentColumns: residentIDs.count, leasedMembers: leases.count) }
        let freshened = conversations.map { conversation in
            Conversation(members: conversation.members.map { useCase.task($0.taskID) ?? $0 })
        }
        orderedConversations = Lineage.parallelColumnOrder(freshened)
        conversationByID = Dictionary(uniqueKeysWithValues: orderedConversations.map { ($0.id, $0) })
        ownerByMember = [:]
        for conversation in orderedConversations {
            for member in conversation.members { ownerByMember[member.taskID] = conversation.id }
        }
        let known = Set(latestTasks.map(\.taskID))
        let resolved = workflowTaskIDs?.allSatisfy { known.contains($0) } ?? true
        arrivals = arrivalTracker.update(orderedConversations.map { (id: $0.id, startedAt: $0.first.startedAt) },
                                         authoritative: activityReady && initialMembershipResolved && resolved)
        descriptors = Dictionary(uniqueKeysWithValues: orderedConversations.map { ($0.id, basePresentation($0, includePrompt: false)) })
        let inputs = updateResidency()
        publishColumns()
        let footerTasks = orderedConversations.map { latestSnapshots[$0.current.taskID] ?? $0.current }
        let footer = EnforcementText.common(footerTasks) ?? Self.fallbackFooter
        if footerText != footer { footerText = footer }
        schedule(inputs)
    }

    private func updateResidency() -> [String: ParallelColumnInput] {
        let stride = ParallelLayout.columnWidth(memberCount: orderedConversations.count, availableWidth: viewportWidth)
            + ParallelLayout.dividerWidth
        let shown = ParallelResidency.visibleIndices(count: orderedConversations.count, offset: viewportOffset,
                                                     width: viewportWidth, stride: stride)
        visibleIDs = Set(shown.map { orderedConversations[$0].id })
        let returning = visibleIDs.subtracting(residentIDs).filter { presentations[$0] != nil }
        refreshingRetainedIDs.formUnion(returning)
        refreshingRetainedIDs.formIntersection(visibleIDs)
        residentIDs = visibleIDs
        let needed = Set(orderedConversations.filter { residentIDs.contains($0.id) }.flatMap { $0.members.map(\.taskID) })
        let leaseStart = MonitorMetrics.begin()
        for id in Set(leases.keys).subtracting(needed) { releaseLease(id) }
        neededMemberIDs = needed
        history.update(conversations: orderedConversations, visible: visibleIDs, states: uiStates)
        let shownConversations = orderedConversations.filter { visibleIDs.contains($0.id) }
        acquisition.update(order: ParallelLeaseOrder.members(shownConversations), existing: Set(leases.keys))
        MonitorMetrics.end(leaseStart, stage: .parallelLeases, residentColumns: residentIDs.count, leasedMembers: leases.count)
        // Keep visited snapshots until membership disappears or the window closes.
        for id in Set(presentations.keys).subtracting(Set(conversationByID.keys)) {
            presentations[id] = nil
            completedInputs[id] = nil
        }
        var inputs: [String: ParallelColumnInput] = [:]
        for conversation in orderedConversations where residentIDs.contains(conversation.id) {
            if readyToRefresh(conversation) { inputs[conversation.id] = captureInput(conversation) }
        }
        return inputs
    }

    private func didAcquire(_ ids: [String], start: UInt64?) {
        let preparation = MonitorMetrics.begin()
        defer { MonitorMetrics.end(preparation, stage: .parallelPreparation, residentColumns: residentIDs.count, leasedMembers: leases.count) }
        MonitorMetrics.end(start, stage: .parallelLeases, residentColumns: residentIDs.count, leasedMembers: leases.count)
        var inputs = desiredInputs
        for id in Set(ids.compactMap { ownerByMember[$0] }) {
            if residentIDs.contains(id), let conversation = conversationByID[id], readyToRefresh(conversation) { inputs[id] = captureInput(conversation) }
        }
        schedule(inputs)
    }

    private func loadOlder(_ id: String) -> Bool {
        guard visibleIDs.contains(id), residentIDs.contains(id) else { return false }
        return history.retryOlder(id)
    }

    private func historyDidChange(_ memberID: String) {
        guard leases[memberID] != nil else { return }
        // History completion follows repository folding; capture its committed items directly.
        itemsByTask[memberID] = useCase.items(for: memberID)
        availabilityByTask[memberID] = useCase.eventsAvailability(for: memberID)
        refreshActivity(memberID: memberID)
    }

    private func refreshActivity(memberID: String) {
        guard let id = ownerByMember[memberID], residentIDs.contains(id), let conversation = conversationByID[id], readyToRefresh(conversation) else { return }
        let start = MonitorMetrics.begin()
        var inputs = desiredInputs
        inputs[id] = captureInput(conversation)
        MonitorMetrics.end(start, stage: .parallelPreparation,
            residentColumns: residentIDs.count, leasedMembers: leases.count)
        schedule(inputs)
    }

    private func readyToRefresh(_ conversation: Conversation) -> Bool {
        guard refreshingRetainedIDs.contains(conversation.id) else { return true }
        // Reacquisition may initially expose an empty tail. Keep the retained snapshot until
        // the requested history boundary has been reconstructed and the stream is ready.
        let ready = conversation.members.allSatisfy { member in
            leases[member.taskID] != nil
                && (availabilityByTask[member.taskID] != .loading || !(itemsByTask[member.taskID] ?? []).isEmpty)
        }
            && !history.state(for: conversation.id, allAcquired: true).isLoading
        if ready { refreshingRetainedIDs.remove(conversation.id) }
        return ready
    }

    private func captureInput(_ conversation: Conversation) -> ParallelColumnInput {
        let members = conversation.members.filter { history.isRevealed($0.taskID, conversationID: conversation.id) }.map { member in
            let snapshot = WorkflowNodePresentation.merged(latestSnapshots[member.taskID], with: member)
            return ParallelMemberInput(task: snapshot, items: itemsByTask[member.taskID] ?? [],
                prompt: snapshot.raw["display_prompt"]?.stringValue ?? useCase.prompt(for: member.taskID),
                availability: availabilityByTask[member.taskID] ?? .loading)
        }
        var base = basePresentation(conversation)
        base.history = history.state(for: conversation.id, allAcquired: conversation.members.allSatisfy { leases[$0.taskID] != nil })
        base.paginationRevision = history.revision(for: conversation.id)
        return ParallelColumnInput(base: base, members: members,
            events: useCase.events(for: conversation.current.taskID), snapshot: latestSnapshots[conversation.current.taskID])
    }

    private func basePresentation(_ conversation: Conversation, includePrompt: Bool = true) -> ParallelColumnPresentation {
        let current = WorkflowNodePresentation.merged(latestSnapshots[conversation.current.taskID], with: conversation.current)
        let currentID = current.taskID
        let resident = includePrompt && residentIDs.contains(conversation.id)
        let promptTask = WorkflowNodePresentation.isWorker(current) ? current :
            WorkflowNodePresentation.merged(latestSnapshots[conversation.first.taskID], with: conversation.first)
        let prompt = resident ? (promptTask.raw["display_prompt"]?.stringValue ?? useCase.prompt(for: promptTask.taskID)) : nil
        let summary = includePrompt ? latestSnapshots[currentID]?.summary : nil
        return ParallelColumnPresentation(id: conversation.id, task: current,
            title: workflowTitles[currentID] ?? useCase.title(conversation.first.taskID),
            subtitle: ParallelColumnModel.subtitle(repoPath: current.repoPath, backend: current.backend, turns: conversation.members.count),
            isBusy: latestBusy.contains(currentID), outcomeMessage: latestOutcomes[currentID], showPrompt: showPrompt,
            prompt: prompt, summary: summary, start: conversation.first.startedAt,
            memberTaskIDs: Set(conversation.members.map(\.taskID)))
    }

    private func publishColumns() {
        let start = MonitorMetrics.begin()
        let oldWrites = presentationWriteCount
        defer {
            MonitorMetrics.end(start, stage: .parallelApply, renderingWrites: presentationWriteCount - oldWrites,
                               residentColumns: residentIDs.count, leasedMembers: leases.count)
        }
        let next = orderedConversations.map { conversation in
            let presentation = presentations[conversation.id] ?? descriptors[conversation.id] ?? basePresentation(conversation, includePrompt: false)
            let metadata = descriptors[conversation.id] ?? presentation
            var column = ParallelColumnModel(id: presentation.id, task: metadata.task, title: metadata.title,
                subtitle: metadata.subtitle, isBusy: metadata.isBusy, outcomeMessage: metadata.outcomeMessage,
                showPrompt: metadata.showPrompt, prompt: presentation.prompt, rows: presentation.rows,
                activityRows: presentation.activityRows, liveStep: presentation.liveStep,
                pendingMessages: presentation.pendingMessages, isLoading: presentation.isLoading, summary: presentation.summary,
                onTapTakeover: { [weak self] in self?.didTapTakeover(taskID: metadata.task.taskID) },
                onTapOpenTask: { [weak self] in self?.routing.selectTask(metadata.task.taskID) }, start: presentation.start)
            column.animatesArrival = arrivals.contains(column.id)
            column.emptyText = presentation.emptyText
            column.onDidPresent = { [weak self] in self?.arrivalTracker.didPresent(conversation.id) }
            column.memberTaskIDs = metadata.memberTaskIDs
            column.isResident = presentations[column.id] != nil || residentIDs.contains(column.id)
            column.isVisible = visibleIDs.contains(column.id)
            column.history = presentation.history
            column.paginationRevision = presentation.paginationRevision
            column.onLoadMore = column.isVisible && (column.history.hasMore || column.history.error != nil)
                ? { [weak self] in self?.loadOlder(conversation.id) ?? false } : nil
            return column
        }
        guard columns.map(\.renderValue) != next.map(\.renderValue) else { return }
        columns = next
        presentationWriteCount += 1
    }

    private func schedule(_ inputs: [String: ParallelColumnInput]) {
        guard desiredInputs != inputs else { return }
        desiredInputs = inputs
        revision &+= 1
        pendingInputs = inputs
        scheduledStart = MonitorMetrics.begin()
        latencyStart = scheduledStart
        worker?.cancel()
        if worker == nil { startPending() }
    }

    private nonisolated static func isBackgroundThread() -> Bool { !Thread.isMainThread }

    private func startPending() {
        guard didSubscribe, let inputs = pendingInputs else { return }
        pendingInputs = nil
        let buildRevision = revision
        let buildEpoch = epoch
        let queueStart = scheduledStart
        let updateStart = latencyStart
        let dirty = inputs.filter { completedInputs[$0.key] != $0.value }
        let build = buildColumns
        let detached = Task.detached(priority: .utility) { () -> [String: ParallelColumnPresentation]? in
            MonitorMetrics.end(queueStart, stage: .parallelScheduling, backgroundThread: Self.isBackgroundThread())
            return await build(dirty)
        }
        worker = Task { [weak self] in
            let result = await withTaskCancellationHandler { await detached.value } onCancel: { detached.cancel() }
            guard let self else { return }
            if didSubscribe, epoch == buildEpoch, revision == buildRevision, let result {
                builtColumnCount += result.count
                for (id, presentation) in result where residentIDs.contains(id) && desiredInputs[id] == inputs[id] {
                    presentations[id] = presentation
                    completedInputs[id] = inputs[id]
                }
                publishColumns()
                MonitorMetrics.end(updateStart, stage: .parallelUpdateLatency)
            }
            worker = nil
            startPending()
        }
    }

    private func didTapTakeover(taskID: String) {
        let dialog = ParallelTakeover.dialog(taskID: taskID,
            task: useCase.task(taskID), snapshot: latestSnapshots[taskID]) { [weak self] in
                guard let self else { return nil }
                let current = conversations.first { $0.members.contains { $0.taskID == taskID } }?.current.taskID
                return (useCase, routing, current)
            }
        guard let dialog else { return }
        publishDialog(dialog)
    }
}
