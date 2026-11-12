import Combine
import Foundation
import HfCommon
import HfRepository
import HfUI
import HfUtilities
import Mockable
import MonitorCore

// MARK: - ParallelVM

/// Presents complete membership with bounded leases and equality-guarded off-main presentation.
@Observable
@MainActor
final class ParallelVM: ParallelViewModel {
    let horizontalPosition: ParallelViewportPosition?
    let groupName: String
    /// Truthful current-membership counts ("1 running · 2 done"), the group top bar badge's text.
    private(set) var statusSummary: String?
    private(set) var showPrompt = false
    private(set) var canCancelAll = false
    private(set) var isEmpty = false
    private(set) var columns: [ParallelColumnModel] = []
    private(set) var selectedConversationID: String?
    @ObservationIgnored var isWorkflowInspector = false
    static let fallbackFooter = "Enforcement differs between these agents; see each task's details."
    /// True only for the standalone group mount (`buildParallelView`); workflow and inspector VMs never publish.
    @ObservationIgnored let publishesTopBar: Bool
    @ObservationIgnored var lastPublishedTopBar: GroupTopBarContent?
    @ObservationIgnored var topBarWriter: ObjectIdentifier?
    @ObservationIgnored let useCase: any ParallelUseCase
    @ObservationIgnored let routing: any ParallelRouting
    @ObservationIgnored private let buildColumns: ParallelColumnsBuild
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var itemCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored let windowAdoption = ParallelWindowAdoption()
    @ObservationIgnored private var availabilityCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored var leaseGenerations: [String: UUID] = [:]
    @ObservationIgnored var ownerByMember: [String: String] = [:]
    @ObservationIgnored var conversationByID: [String: Conversation] = [:]
    @ObservationIgnored private var leases: [String: any EventStreamLease] = [:]
    @ObservationIgnored var itemsByTask: [String: [TimelineItem]] = [:]
    @ObservationIgnored var availabilityByTask: [String: EventAvailability] = [:]
    @ObservationIgnored var didSubscribe = false
    @ObservationIgnored private var latestTasks: [TaskInfo] = []
    @ObservationIgnored var latestSnapshots: [String: TaskInfo] = [:]
    @ObservationIgnored var latestBusy: Set<String> = []
    @ObservationIgnored private var latestOutcomes: [String: String] = [:]
    @ObservationIgnored var messageDispatches: Set<String> = []
    /// Send-now refusals keyed by task id, then message id.
    @ObservationIgnored var messageNotes: [String: [String: String]] = [:]
    @ObservationIgnored var memberIDs: [String] = []
    @ObservationIgnored var conversations: [Conversation] = []
    @ObservationIgnored private var workflowTaskIDs: [String]?
    @ObservationIgnored private var workflowFocusedTaskIDs: Set<String>?
    @ObservationIgnored private var workflowTitles: [String: String] = [:]
    @ObservationIgnored private var initialMembershipResolved = false
    @ObservationIgnored private var activityReady = false
    @ObservationIgnored private var arrivalTracker = PanelArrivalTracker()
    @ObservationIgnored private var viewportOffset: CGFloat = 0
    @ObservationIgnored private var viewportWidth: CGFloat = 0
    @ObservationIgnored var residentIDs: Set<String> = []
    @ObservationIgnored var refreshingRetainedIDs: Set<String> = []
    @ObservationIgnored private var visibleIDs: Set<String> = []
    @ObservationIgnored private var neededMemberIDs: Set<String> = []
    @ObservationIgnored lazy var history = ParallelActivityHistory(useCase: useCase,
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
    @ObservationIgnored var uiStates: [String: ParallelColumnUIState] = [:]
    /// View prompt: stored first requests by prompt task, their subscriptions and the lease generation each was read in.
    @ObservationIgnored var requestStates: [String: TaskRequestReadState] = [:]
    @ObservationIgnored var requestSubscriptions: [String: AnyCancellable] = [:]
    @ObservationIgnored var requestReadGenerations: [String: UUID] = [:]
    @ObservationIgnored var descriptors: [String: ParallelColumnPresentation] = [:]
    @ObservationIgnored var presentations: [String: ParallelColumnPresentation] = [:]
    @ObservationIgnored var completedInputs: [String: ParallelColumnInput] = [:]
    @ObservationIgnored private var desiredInputs: [String: ParallelColumnInput] = [:]
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var pendingInputs: [String: ParallelColumnInput]?
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored var epoch: UInt64 = 0
    @ObservationIgnored private var scheduledStart: UInt64?
    @ObservationIgnored private var latencyStart: UInt64?
    var isPresentationSettled: Bool { worker == nil && pendingInputs == nil && acquisition.isSettled }
    var leasedMemberCount: Int { leases.count }
    var residentColumnCount: Int { residentIDs.count }
    var retainedColumnStateCount: Int { uiStates.count }
    @ObservationIgnored var orderedConversations: [Conversation] = []
    @ObservationIgnored private var arrivals: Set<String> = []
    @ObservationIgnored private(set) var presentationWriteCount = 0
    @ObservationIgnored private(set) var builtColumnCount = 0
    @ObservationIgnored private(set) var sourceUpdateCount = 0
    @ObservationIgnored let outcomeMemory = ParallelOutcomeMemory()

    func updateViewport(offset: CGFloat, width: CGFloat) {
        guard viewportOffset != offset || viewportWidth != width else { return }
        let start = MonitorMetrics.begin()
        defer { MonitorMetrics.end(start, stage: .parallelViewport, residentColumns: residentIDs.count, leasedMembers: leases.count) }
        viewportOffset = offset
        viewportWidth = width
        guard didSubscribe else { return }
        let nextVisible = ParallelActivityViewport.conversationIDs(orderedConversations, inspector: isWorkflowInspector,
                                                              selectedID: selectedConversationID, offset: viewportOffset, width: viewportWidth)
        guard nextVisible != visibleIDs else { return }
        let inputs = updateResidency()
        publishColumns()
        schedule(inputs)
    }

    init(groupName: String, useCase: any ParallelUseCase, routing: any ParallelRouting,
         horizontalPosition: ParallelViewportPosition = ParallelViewportPosition(), publishesTopBar: Bool = false,
         buildColumns: @escaping ParallelColumnsBuild = ParallelPresentationBuilder.buildColumns) {
        self.publishesTopBar = publishesTopBar
        self.horizontalPosition = horizontalPosition
        self.groupName = groupName
        self.useCase = useCase
        self.routing = routing
        self.buildColumns = buildColumns
    }

    func didAppear() {
        subscribeIfNeeded()
        activateTopBar()
    }

    /// Workflow membership follows persisted dispatch associations.
    func setWorkflowTaskIDs(_ ids: [String], focusedTaskIDs: Set<String>? = nil, titles: [String: String] = [:]) {
        guard workflowTaskIDs != ids || workflowFocusedTaskIDs != focusedTaskIDs || workflowTitles != titles else { return }
        workflowTaskIDs = ids
        workflowFocusedTaskIDs = focusedTaskIDs
        workflowTitles = titles
        if didSubscribe { recomputeMembersAndLeases() }
    }

    func didDisappear() {
        if publishesTopBar {
            routing.deactivateTopBar(tag: topBarTag)
            routing.clearTopBar(tag: topBarTag)
            lastPublishedTopBar = nil
        }
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
        cancelRequestReads()
        orderedConversations.removeAll()
        selectedConversationID = nil
        viewportWidth = 0
        columns.removeAll()
        cancellables.removeAll()
        itemCancellables.removeAll()
        availabilityCancellables.removeAll()
        windowAdoption.reset()
        recoveryCancellables.removeAll()
        recoveryFrames.removeAll()
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
        syncRequestReads()
        for id in descriptors.keys { descriptors[id]?.showPrompt = showPrompt }
        var inputs = desiredInputs
        for id in inputs.keys { inputs[id]?.base.showPrompt = showPrompt }
        publishColumns()
        schedule(inputs)
        MonitorMetrics.end(start, stage: .parallelPreparation,
            residentColumns: residentIDs.count, leasedMembers: leases.count)
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
        // Independent title updates refresh the column without waiting for another publisher.
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
        MonitorMetrics.end(preparation, stage: .parallelPreparation, residentColumns: residentIDs.count, leasedMembers: leases.count)
        recompute()
    }

    @ObservationIgnored var recoveryFrames: [String: RecoveredTranscriptFrame] = [:]
    @ObservationIgnored var recoveryCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored var observationFrames: [String: EventObservationFrame] = [:]

    private func acquireLease(_ taskID: String) {
        guard leases[taskID] == nil else { return }
        let generation = UUID()
        leaseGenerations[taskID] = generation
        leases[taskID] = useCase.acquireEventLease(taskID)
        if let owner = ownerByMember[taskID] { history.acquire(taskID, conversationID: owner, state: columnState(for: owner)) }
        acquireRecovery(taskID, generation: generation)
        applyObservation(useCase.observation(for: taskID), taskID: taskID)
        itemCancellables[taskID] = useCase.observationPublisher(for: taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] frame in
                guard let self, leaseGenerations[taskID] == generation,
                      useCase.observation(for: taskID) == frame else { return }
                applyObservation(frame, taskID: taskID)
                refreshActivity(memberID: taskID)
            }
    }

    private func releaseLease(_ taskID: String) {
        releaseRequest(taskID)
        history.release(taskID)
        leases[taskID]?.release()
        leases[taskID] = nil
        leaseGenerations[taskID] = nil
        itemCancellables[taskID]?.cancel()
        itemCancellables[taskID] = nil
        availabilityCancellables[taskID]?.cancel()
        availabilityCancellables[taskID] = nil
        recoveryCancellables[taskID] = nil
        recoveryFrames[taskID] = nil
        observationFrames[taskID] = nil
        itemsByTask[taskID] = nil
        availabilityByTask[taskID] = nil
    }

    /// Refresh metadata, retaining the ownership skeleton for activity and viewport updates.
    func recompute() {
        let preparationStart = MonitorMetrics.begin()
        defer { MonitorMetrics.end(preparationStart, stage: .parallelPreparation, residentColumns: residentIDs.count, leasedMembers: leases.count) }
        let freshened = conversations.map { conversation in
            Conversation(members: conversation.members.map { useCase.task($0.taskID) ?? $0 })
        }
        orderedConversations = Lineage.parallelColumnOrder(freshened)
        conversationByID = Dictionary(uniqueKeysWithValues: orderedConversations.map { ($0.id, $0) })
        if isWorkflowInspector, selectedConversationID.map({ conversationByID[$0] == nil }) ?? true {
            selectedConversationID = orderedConversations.first?.id
        }
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
        syncRequestReads()
        publishColumns()
        publishHeaderClaims()
        schedule(inputs)
    }

    /// Apply complete-membership header values and publish the group top bar content when it changed.
    private func publishHeaderClaims() {
        let tasks = orderedConversations.map { latestSnapshots[$0.current.taskID] ?? $0.current }
        let header = ParallelHeaderPresentation(tasks: tasks, fallback: Self.fallbackFooter)
        if statusSummary != header.statusSummary { statusSummary = header.statusSummary }
        publishTopBar(initialMembershipResolved ? header.content(title: groupName) : loadingTopBarContent)
    }

    private func updateResidency() -> [String: ParallelColumnInput] {
        visibleIDs = ParallelActivityViewport.conversationIDs(orderedConversations, inspector: isWorkflowInspector,
                                                              selectedID: selectedConversationID, offset: viewportOffset, width: viewportWidth)
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
        syncRequestReads()
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
        refreshActivity(memberID: memberID)
    }

    func refreshActivity(memberID: String) {
        guard let id = ownerByMember[memberID], residentIDs.contains(id), let conversation = conversationByID[id], readyToRefresh(conversation) else { return }
        let start = MonitorMetrics.begin()
        var inputs = desiredInputs
        inputs[id] = captureInput(conversation)
        MonitorMetrics.end(start, stage: .parallelPreparation,
            residentColumns: residentIDs.count, leasedMembers: leases.count)
        schedule(inputs)
    }

    private func readyToRefresh(_ conversation: Conversation) -> Bool {
        let wasPending = windowAdoption.pending.contains(conversation.id)
        if windowAdoption.needsAdoption(id: conversation.id, previous: completedInputs[conversation.id], frames: observationFrames) {
            publishColumns()
            return false
        }
        if wasPending { resetObservationReadingWindow(conversation.id) }
        guard refreshingRetainedIDs.contains(conversation.id) else { return true }
        // Preserve retained content until reacquisition reconstructs its history and ready stream.
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
                prompt: nil,
                availability: availabilityByTask[member.taskID] ?? .loading, observation: observationFrames[member.taskID],
                recoveredTranscript: recoveryFrames[member.taskID] ?? .init())
        }
        var base = basePresentation(conversation)
        base.history = history.state(for: conversation.id, allAcquired: conversation.members.allSatisfy { leases[$0.taskID] != nil })
        base.paginationRevision = history.revision(for: conversation.id)
        return ParallelColumnInput(base: base, members: members,
            events: observationFrames[conversation.current.taskID]?.events ?? [], snapshot: latestSnapshots[conversation.current.taskID])
    }

    private func basePresentation(_ conversation: Conversation, includePrompt: Bool = true) -> ParallelColumnPresentation {
        let current = WorkflowNodePresentation.merged(latestSnapshots[conversation.current.taskID], with: conversation.current)
        let currentID = current.taskID
        let summary = includePrompt ? latestSnapshots[currentID]?.summary : nil
        return ParallelColumnPresentation(id: conversation.id, task: current,
            title: workflowTitles[currentID] ?? useCase.title(conversation.first.taskID),
            subtitle: isWorkflowInspector
                ? ParallelColumnModel.subtitle(repoPath: current.repoPath, backend: current.backend, turns: conversation.members.count) : "",
            caption: ParallelLaneStatus.caption(current: current), harnessName: ParallelLaneStatus.harnessName(current: current),
            status: isWorkflowInspector ? nil : laneStatus(current),
            isBusy: latestBusy.contains(currentID) || messageDispatches.contains(currentID), outcomeMessage: latestOutcomes[currentID], showPrompt: showPrompt,
            summary: summary, start: conversation.first.startedAt,
            memberTaskIDs: Set(conversation.members.map(\.taskID)))
    }

    func publishColumns() {
        let start = MonitorMetrics.begin()
        let oldWrites = presentationWriteCount
        defer {
            MonitorMetrics.end(start, stage: .parallelApply, renderingWrites: presentationWriteCount - oldWrites,
                               residentColumns: residentIDs.count, leasedMembers: leases.count)
        }
        let next = orderedConversations.map { conversation in
            let presentation = presentations[conversation.id] ?? descriptors[conversation.id] ?? basePresentation(conversation, includePrompt: false)
            let metadata = descriptors[conversation.id] ?? presentation
            var column = ParallelColumnModelBuilder.build(presentation: presentation, metadata: metadata,
                onTapTakeover: isWorkflowInspector ? { [weak self] in self?.didTapTakeover(taskID: metadata.task.taskID) } : nil,
                onTapOpenTask: { [weak self] in self?.routing.selectTask(metadata.task.taskID) }, onSelectTask: { [weak self] in self?.routing.selectTask($0) })
            column.onSubmitMessage = { [weak self] text, now in self?.submitMessage(text, conversationID: conversation.id, now: now) ?? false }
            column.onCancelMessage = { [weak self] messageID in self?.cancelMessage(messageID, conversationID: conversation.id) }
            windowAdoption.prepareColumn(&column, id: conversation.id) { [weak self] in self?.adoptObservationWindow(conversation.id) }
            column.workMessages = WorkMessageBubble.applying(column.workMessages, notes: messageNotes[metadata.task.taskID] ?? [:])
            column.chrome = isWorkflowInspector ? .inspector : .lane
            applyRequest(to: &column, conversationID: conversation.id)
            if !isWorkflowInspector { column.status = laneStatus(metadata.task) }
            column.animatesArrival = arrivals.contains(column.id)
            column.onDidPresent = { [weak self] in self?.arrivalTracker.didPresent(conversation.id) }
            column.isResident = presentations[column.id] != nil || residentIDs.contains(column.id)
            column.isVisible = visibleIDs.contains(column.id)
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
        var dirty = inputs.filter { completedInputs[$0.key] != $0.value }
        preparePreviousActivity(&dirty)
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
}

// MARK: - Workflow activity suspension

extension ParallelVM {
    /// Stops hidden inspector work while retaining visited feed presentation and reading state.
    func suspendWorkflowActivity() {
        updateViewport(offset: 0, width: 0)
        epoch &+= 1
        revision &+= 1
        worker?.cancel()
        worker = nil
        acquisition.cancel()
        pendingInputs = nil
        neededMemberIDs.removeAll()
        for id in Array(leases.keys) { history.release(id) }
        history.teardown()
        cancellables.removeAll()
        itemCancellables.removeAll()
        availabilityCancellables.removeAll()
        windowAdoption.reset()
        recoveryCancellables.removeAll()
        recoveryFrames.removeAll()
        for lease in leases.values { lease.release() }
        leases.removeAll()
        leaseGenerations.removeAll()
        didSubscribe = false
    }
}

// MARK: - Workflow inspector residency

extension ParallelVM {
    /// Independent workflow inspector ownership with the same activity dependencies.
    func makeWorkflowActivity() -> ParallelVM {
        let activity = ParallelVM(groupName: groupName, useCase: useCase, routing: routing, buildColumns: buildColumns)
        activity.isWorkflowInspector = true
        return activity
    }

    /// Explicit inspector selection changes residency even when its geometry is unchanged.
    func selectConversation(_ id: String) {
        guard isWorkflowInspector, conversationByID[id] != nil, selectedConversationID != id else { return }
        selectedConversationID = id
        guard didSubscribe else { return }
        let inputs = updateResidency()
        publishColumns()
        schedule(inputs)
    }
}
