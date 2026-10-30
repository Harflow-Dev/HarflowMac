import Foundation
import MonitorCore

// MARK: - NeedsYouCore

/// The acquisition state machine behind Needs you. All mutable state is actor-isolated; engine
/// calls suspend the actor, so every step is written to leave the state consistent at each `await`.
actor NeedsYouCore {
    struct Output {
        let revision: Int
        let snapshot: NeedsYouSnapshot
        let events: [NeedsYouEvent]
    }

    static let invocationBudget = 24
    static let maxStatusReads = 12
    static let maxWorkflowPages = 10
    static let maxTaskPages = 4
    static let maxApprovalPages = 4
    static let suppressionSeconds: TimeInterval = 60

    private struct Header {
        let id: String
        let name: String
        let status: String
        let kind: String
        let parent: String?
    }

    private struct Source {
        var items: [NeedsYouItem]
        var visible: Bool
    }

    private struct Budget {
        var remaining: Int
        mutating func take() -> Bool {
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
    }

    private struct ObservationFailure: Error { let observation: Observation }

    private enum Observation {
        case ready([NeedsYouItem])
        case unreadable
        case unsupported
        case deferred
    }

    private let engine: any NeedsYouEngine
    private let now: @Sendable () -> Date

    private var pass = 0
    private var revision = 0
    private var phase = NeedsYouSnapshot.Phase.loading
    private var sources: [String: Source] = [:]
    private var lastVisit: [String: Int] = [:]
    private var visitedEver: Set<String> = []
    private var unreadable: Set<String> = []
    private var unsupportedRoots: Set<String> = []
    private var deferred = 0
    private var suppressed: [String: Date] = [:]

    private var workflowCursor: String?
    private var workflowAccum: [String: Header] = [:]
    private var workflowKnown: [String: Header] = [:]
    private var workflowComplete = false
    private var names: [String: String] = [:]

    private var taskCursor: String?
    private var taskAccum: [String: TaskInfo] = [:]
    private var taskKnown: [String: TaskInfo] = [:]
    private var taskComplete = false

    init(engine: any NeedsYouEngine, now: @escaping @Sendable () -> Date) {
        self.engine = engine
        self.now = now
    }

    // MARK: - Pass

    func runPass() async -> Output {
        pass += 1
        var budget = Budget(remaining: Self.invocationBudget)
        var events: [NeedsYouEvent] = []
        deferred = 0
        let baseline = phase == .loading
        await inventoryWorkflows(&budget, events: &events)
        await inventoryTasks(&budget, events: &events)
        await readRoots(&budget, events: &events, baseline: baseline)
        await readTasks(&budget, events: &events, baseline: baseline)
        expireSuppression()
        updatePhase()
        return output(events)
    }

    // MARK: - Answers

    func markAnswered(_ id: String) -> Output {
        suppressed[id] = now()
        var events: [NeedsYouEvent] = []
        for key in sources.keys where sources[key]?.items.contains(where: { $0.id == id }) == true {
            sources[key]?.items.removeAll { $0.id == id }
        }
        events.append(.resolved(id))
        return output(events)
    }

    /// The root's current attention fingerprint, re-read before a recovery is submitted.
    func currentRecoveryID(root: String) async -> String? {
        guard let status = try? await engine.workflowStatus(root), status.isQualified, let state = status.interactionState else { return nil }
        let plan = NeedsYouMapper.plan(root: status, state: state, names: names)
        return plan.recovery?.id
    }

    // MARK: - Workflow inventory

    private enum Step { case more, finished, failed }

    private func inventoryWorkflows(_ budget: inout Budget, events: inout [NeedsYouEvent]) async {
        var pages = 0
        var step = Step.more
        while step == .more, pages < Self.maxWorkflowPages, budget.take() {
            step = await workflowStep()
            pages += 1
        }
        switch step {
        case .failed:
            workflowCursor = nil
            workflowAccum = [:]
            unreadable.insert("inventory:workflow")
        case .more:
            unreadable.remove("inventory:workflow")
            if workflowCursor != nil { deferred += 1 }
        case .finished:
            unreadable.remove("inventory:workflow")
            // A complete inventory is an authoritative observation that a root no longer needs input.
            let keep = Set(candidateRoots().map { "workflow:\($0.id)" })
            for key in sources.keys where key.hasPrefix("workflow:") && !keep.contains(key) { retire(key, events: &events) }
        }
    }

    private func workflowStep() async -> Step {
        let page: HistoryPage
        do { page = try await engine.workflowPage(cursor: workflowCursor) } catch { return .failed }
        guard page.catalogState.isReady, !page.historyIncomplete, !page.authorityIncomplete else { return .failed }
        for header in page.relatedHeaders { remember(header) }
        for item in page.items { if let value = remember(item) { workflowAccum[value.id] = value } }
        guard page.hasMore, let next = page.nextCursor else {
            workflowKnown = workflowAccum
            workflowAccum = [:]
            workflowCursor = nil
            workflowComplete = true
            return .finished
        }
        workflowCursor = next
        return .more
    }

    @discardableResult
    private func remember(_ object: [String: JSONValue]) -> Header? {
        guard let id = object["workflow_run_id"]?.stringValue, !id.isEmpty else { return nil }
        let name = object["name"]?.stringValue ?? ""
        if !name.isEmpty { names[id] = name }
        return Header(id: id, name: name, status: object["status"]?.stringValue ?? "", kind: object["kind"]?.stringValue ?? "",
                      parent: object["parent_workflow_run_id"]?.stringValue)
    }

    private func candidateRoots() -> [Header] {
        let merged = workflowKnown.merging(workflowAccum) { _, new in new }
        return merged.values
.filter {
            ($0.parent ?? "").isEmpty && $0.kind != "builder" && ["needs_input", "needs_attention"].contains($0.status)
        }
.sorted { $0.id < $1.id }
    }

    // MARK: - Task inventory

    private func inventoryTasks(_ budget: inout Budget, events: inout [NeedsYouEvent]) async {
        var pages = 0
        var step = Step.more
        while step == .more, pages < Self.maxTaskPages, budget.take() {
            step = await taskStep()
            pages += 1
        }
        switch step {
        case .failed:
            taskCursor = nil
            taskAccum = [:]
            unreadable.insert("inventory:task")
        case .more:
            unreadable.remove("inventory:task")
            if taskCursor != nil { deferred += 1 }
        case .finished:
            unreadable.remove("inventory:task")
            let keep = Set(taskKnown.keys.map { "task:\($0)" })
            for key in sources.keys where key.hasPrefix("task:") && !keep.contains(key) { retire(key, events: &events) }
        }
    }

    private func taskStep() async -> Step {
        let page: TaskHistoryPage
        do { page = try await engine.taskPage(cursor: taskCursor) } catch { return .failed }
        guard page.page.catalogState.isReady, !page.page.historyIncomplete, !page.page.authorityIncomplete else { return .failed }
        for task in page.items { taskAccum[task.taskID] = task }
        guard page.page.hasMore, let next = page.page.nextCursor else {
            taskKnown = taskAccum
            taskAccum = [:]
            taskCursor = nil
            taskComplete = true
            return .finished
        }
        taskCursor = next
        return .more
    }

    private func retire(_ key: String, events: inout [NeedsYouEvent]) {
        guard let source = sources.removeValue(forKey: key) else { return }
        for item in source.items { events.append(.resolved(item.id)) }
        unreadable.remove(key)
        unsupportedRoots.remove(key)
    }

    // MARK: - Workflow roots

    private func readRoots(_ budget: inout Budget, events: inout [NeedsYouEvent], baseline: Bool) async {
        let candidates = candidateRoots().sorted {
            let first = lastVisit["workflow:\($0.id)"] ?? -1, second = lastVisit["workflow:\($1.id)"] ?? -1
            return first == second ? $0.id < $1.id : first < second
        }
        var visited = 0
        for header in candidates {
            guard visited < Self.maxStatusReads, budget.remaining > 0 else { break }
            visited += 1
            let key = "workflow:\(header.id)"
            lastVisit[key] = pass
            let observation = await observeRoot(header.id, &budget)
            apply(observation, key: key, events: &events, baseline: baseline)
        }
        deferred += max(0, candidates.count - visited)
    }

    private func observeRoot(_ id: String, _ budget: inout Budget) async -> Observation {
        guard budget.take() else { return .deferred }
        let status: WorkflowMonitorStatus
        do { status = try await engine.workflowStatus(id) } catch { return .unreadable }
        guard status.isQualified else { return .unreadable }
        guard let state = status.interactionState else { return .unsupported }
        guard status.runID == id else { return .unreadable }
        let plan = NeedsYouMapper.plan(root: status, state: state, names: names)
        var items: [NeedsYouItem] = []
        for candidate in plan.questions {
            switch await offeredAnswers(for: candidate, root: status, &budget) {
            case .failure(let failure): return failure.observation
            case .success(let offered):
                items.append(NeedsYouMapper.question(candidate: candidate, root: status, state: state, names: names, offered: offered))
            }
        }
        if let recovery = plan.recovery { items.append(recovery) }
        return .ready(items)
    }

    /// Structured usage-limit answers come from the source run's own `usage_limit_recovery`; a worker
    /// usage limit has none and is an ordinary free-text question.
    private func offeredAnswers(
        for candidate: NeedsYouMapper.Candidate, root: WorkflowMonitorStatus, _ budget: inout Budget
    ) async -> Result<[String]?, ObservationFailure> {
        var recovery = root.usageLimitRecovery
        if candidate.needsSourceRead {
            guard candidate.entry.isUsageLimit else { return .success(nil) }
            guard budget.take() else { return .failure(ObservationFailure(observation: .deferred)) }
            guard let child = try? await engine.workflowStatus(candidate.entry.workflowRunID), child.isQualified else {
                return .failure(ObservationFailure(observation: .unreadable))
            }
            recovery = child.usageLimitRecovery
        }
        guard let recovery, recovery.decisionID == candidate.entry.decisionID, !recovery.choices.isEmpty else { return .success(nil) }
        return .success(recovery.choices)
    }

    // MARK: - Tasks and approvals

    private func readTasks(_ budget: inout Budget, events: inout [NeedsYouEvent], baseline: Bool) async {
        let all = taskKnown.merging(taskAccum) { _, new in new }
        let ordered = all.keys.sorted {
            let first = lastVisit["task:\($0)"] ?? -1, second = lastVisit["task:\($1)"] ?? -1
            return first == second ? $0 < $1 : first < second
        }
        var index = 0
        var capability: Bool?
        while index < ordered.count, budget.take() {
            let chunk = Array(ordered[index ..< min(index + 100, ordered.count)])
            index += chunk.count
            let outcomes: [String: Result<TaskInfo, ToolError>]
            do { outcomes = try await engine.taskStatuses(chunk) } catch {
                unreadable.insert("batch:task")
                for id in chunk { apply(.unreadable, key: "task:\(id)", events: &events, baseline: baseline, countUnreadable: false) }
                continue
            }
            unreadable.remove("batch:task")
            for id in chunk {
                let key = "task:\(id)"
                lastVisit[key] = pass
                guard case .success(let info)? = outcomes[id] else {
                    apply(.unreadable, key: key, events: &events, baseline: baseline)
                    continue
                }
                let observation = await observeTask(info, &budget, capability: &capability)
                apply(observation, key: key, events: &events, baseline: baseline)
            }
        }
        deferred += max(0, ordered.count - index)
    }

    private func observeTask(_ info: TaskInfo, _ budget: inout Budget, capability: inout Bool?) async -> Observation {
        let summary = info.raw["approval_summary"]?.objectValue
        guard let awaiting = info.awaitingDecisionCount, awaiting > 0 else { return .ready([]) }
        if summary?["error"] != nil || summary?["interaction_state"]?.stringValue == "approval_state_uncertain" { return .unreadable }
        var rows: [CallerApprovalRequest] = []
        var cursor: String?
        var pages = 0
        repeat {
            guard budget.take() else { return .deferred }
            guard let page = try? await engine.approvalPage(taskID: info.taskID, cursor: cursor) else { return .unreadable }
            rows += page.requests.filter(\.mayBeAnsweredFromMonitor)
            cursor = page.nextCursor
            pages += 1
        } while cursor != nil && pages < Self.maxApprovalPages
        if cursor != nil { return .deferred }
        let held = Dictionary(sources["task:\(info.taskID)"]?.items.compactMap { item in item.approval.map { (item.id, $0) } } ?? [],
                              uniquingKeysWith: { first, _ in first })
        var items: [NeedsYouItem] = []
        for row in rows {
            if let existing = held["approval:\(row.taskID):\(row.id)"], existing.revision == row.revision, existing.isSameCurrent(as: row) {
                items.append(NeedsYouMapper.approval(request: existing, task: info))
                continue
            }
            switch await acquireDetail(row, &budget, capability: &capability) {
            case .failure(let failure): return failure.observation
            case .success(let detail): if let detail { items.append(NeedsYouMapper.approval(request: detail, task: info)) }
            }
        }
        return .ready(items)
    }

    /// The complete current request, or nil when it is not answerable from the Monitor.
    private func acquireDetail(
        _ row: CallerApprovalRequest, _ budget: inout Budget, capability: inout Bool?
    ) async -> Result<CallerApprovalRequest?, ObservationFailure> {
        guard budget.take() else { return .failure(ObservationFailure(observation: .deferred)) }
        guard let detail = try? await engine.approvalDetail(taskID: row.taskID, requestID: row.id) else {
            return .failure(ObservationFailure(observation: .unreadable))
        }
        guard detail.isPending, detail.complete, detail.mayBeAnsweredFromMonitor, detail.hasKnownState, detail.hasValidIdentity else {
            return .success(nil)
        }
        if !detail.isMonitorOwned {
            if capability == nil { capability = try? await engine.supportsMonitorApprovalResponses() }
            guard capability == true else { return .success(nil) }
        }
        return .success(detail)
    }

    // MARK: - Applying observations

    private func apply(_ observation: Observation, key: String, events: inout [NeedsYouEvent], baseline: Bool, countUnreadable: Bool = true) {
        switch observation {
        case .deferred:
            deferred += 1
        case .unreadable:
            if countUnreadable { unreadable.insert(key) }
            sources[key, default: Source(items: [], visible: false)].visible = false
        case .unsupported:
            unreadable.remove(key)
            unsupportedRoots.insert(key)
            sources[key, default: Source(items: [], visible: false)].visible = false
        case .ready(let items):
            unreadable.remove(key)
            unsupportedRoots.remove(key)
            let firstReady = visitedEver.insert(key).inserted
            let previous = sources[key]
            let oldIDs = Set((previous?.items ?? []).map(\.id))
            let newIDs = Set(items.map(\.id))
            for id in suppressed.keys where !newIDs.contains(id) && oldIDs.contains(id) { suppressed[id] = nil }
            for item in previous?.items ?? [] where !newIDs.contains(item.id) { events.append(.resolved(item.id)) }
            for item in items where !oldIDs.contains(item.id) && suppressed[item.id] == nil {
                events.append(.appeared(item, sourceBaseline: firstReady && baseline))
            }
            sources[key] = Source(items: items, visible: true)
        }
    }

    private func expireSuppression() {
        let cutoff = now().addingTimeInterval(-Self.suppressionSeconds)
        suppressed = suppressed.filter { $0.value > cutoff }
    }

    private func updatePhase() {
        guard phase == .loading, workflowComplete, taskComplete else { return }
        let roots = candidateRoots().map { "workflow:\($0.id)" }
        let tasks = taskKnown.keys.map { "task:\($0)" }
        if (roots + tasks).allSatisfy(visitedEver.contains) { phase = .ready }
    }

    // MARK: - Output

    private func output(_ events: [NeedsYouEvent]) -> Output {
        revision += 1
        let visible = sources.values.filter(\.visible).flatMap(\.items).filter { suppressed[$0.id] == nil }
        let snapshot = NeedsYouSnapshot(
            phase: phase, items: visible.sorted(by: NeedsYouItem.ordered), unreadableSourceCount: unreadable.count,
            deferredSourceCount: deferred, workflowInputsUnsupported: !unsupportedRoots.isEmpty
        )
        return Output(revision: revision, snapshot: snapshot, events: events)
    }
}
