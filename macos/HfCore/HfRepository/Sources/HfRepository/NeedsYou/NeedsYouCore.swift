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

    /// Process launches per pass. `CtlClient` launches a `version-info` handshake before every command, so a
    /// command costs `launchesPerCommand`; the budget is therefore about 24 commands.
    static let invocationBudget = 48
    static let launchesPerCommand = 2
    static let inventoryLaunchBudget = 20
    static let maxStatusReads = 12
    static let maxWorkflowPages = 6
    static let maxTaskPages = 4
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
        /// Previous items whose entries could not be re-read this pass: hidden, not resolved.
        var withheld: [NeedsYouItem] = []
        var visible: Bool
    }

    private struct Budget {
        var remaining: Int
        mutating func take(_ cost: Int = NeedsYouCore.launchesPerCommand) -> Bool {
            guard remaining >= cost else { return false }
            remaining -= cost
            return true
        }
    }

    private struct ObservationFailure: Error { let observation: Observation }

    private enum Observation {
        case ready([NeedsYouItem], withheld: Set<String>, childFailures: Set<String>)
        case unreadable
        case unsupported
        case deferred

        static func ready(_ items: [NeedsYouItem]) -> Observation { .ready(items, withheld: [], childFailures: []) }
    }

    private enum Acquired {
        case eligible(CallerApprovalRequest)
        case skipped
    }

    /// Per-task approval acquisition that survives passes, so a long listing or many details make progress.
    private struct ApprovalProgress {
        var cursor: String?
        var listComplete = false
        var seenCursors: Set<String> = []
        var rows: [CallerApprovalRequest] = []
        var details: [String: Acquired] = [:]
    }

    /// The root's checkpoint as re-read before a recovery is sent.
    enum RecoveryCheck: Equatable {
        case current(String?)
        case unreadable
    }

    private let engine: any NeedsYouEngine
    private let now: @Sendable () -> Date

    private var pass = 0
    private var revision = 0
    private var phase = NeedsYouSnapshot.Phase.loading
    private var sources: [String: Source] = [:]
    private var lastVisit: [String: Int] = [:]
    private var visitedEver: Set<String> = []
    /// Sources with any terminal observation (ready, unreadable or unsupported) since launch.
    private var attempted: Set<String> = []
    private var childFailures: [String: Set<String>] = [:]
    /// Successful child reads kept per root until the root has been read completely, so an oversized root advances.
    private var childReads: [String: [String: WorkflowMonitorStatus]] = [:]
    private var visitFailures: Set<String> = []
    /// Reads taken during the current visit by bare child id, so two decisions from one child cost one read.
    private var visitReads: [String: WorkflowMonitorStatus] = [:]
    /// Where each root's next visit starts among its entries, advancing past every attempted child (failed ones included).
    private var childCursor: [String: String] = [:]
    private var approvalProgress: [String: ApprovalProgress] = [:]
    private var unreadable: Set<String> = []
    private var unsupportedRoots: Set<String> = []
    private var deferred = 0
    private var suppressed: [String: Date] = [:]

    private enum ChildFailure: Error { case unreadable, deferred }

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
        var inventory = Budget(remaining: min(Self.inventoryLaunchBudget, budget.remaining))
        let granted = inventory.remaining
        await inventoryWorkflows(&inventory, events: &events)
        await inventoryTasks(&inventory, events: &events)
        budget.remaining -= granted - inventory.remaining
        // Alternate which queue goes first and give it at most half of what is left, so neither starves the other.
        let rootsFirst = pass % 2 == 0
        for readRootsNow in [rootsFirst, !rootsFirst] {
            var share = Budget(remaining: readRootsNow == rootsFirst ? (budget.remaining + 1) / 2 : budget.remaining)
            let allotted = share.remaining
            if readRootsNow {
                await readRoots(&share, events: &events, baseline: baseline)
            } else {
                await readTasks(&share, events: &events, baseline: baseline)
            }
            budget.remaining -= allotted - share.remaining
        }
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
    func currentRecoveryID(root: String) async -> RecoveryCheck {
        guard let status = try? await engine.workflowStatus(root), status.isQualified, let state = status.interactionState else {
            return .unreadable
        }
        let plan = NeedsYouMapper.plan(root: status, state: state, names: names)
        return .current(plan.recovery?.id)
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
        for item in source.items + source.withheld { events.append(.resolved(item.id)) }
        unreadable.remove(key)
        unsupportedRoots.remove(key)
        unreadable.subtract(childFailures.removeValue(forKey: key) ?? [])
        approvalProgress[key] = nil
        childReads[key] = nil
        childCursor[key] = nil
    }

    // MARK: - Workflow roots

    private func readRoots(_ budget: inout Budget, events: inout [NeedsYouEvent], baseline: Bool) async {
        let candidates = candidateRoots().sorted {
            let first = lastVisit["workflow:\($0.id)"] ?? -1, second = lastVisit["workflow:\($1.id)"] ?? -1
            return first == second ? $0.id < $1.id : first < second
        }
        var visited = 0
        for header in candidates {
            guard visited < Self.maxStatusReads, budget.remaining >= Self.launchesPerCommand else { break }
            visited += 1
            let key = "workflow:\(header.id)"
            let observation = await observeRoot(header.id, &budget)
            // Every attempted root rotates to the back, so roots with failing or oversized children cannot block the rest;
            // their persisted child reads let them finish across visits.
            if case .deferred = observation {} else { lastVisit[key] = pass }
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
        var withheld = Set<String>()
        var failures = Set<String>()
        var firstDeferred: Int?
        visitFailures = []
        visitReads = [:]
        let rootKey = "workflow:\(id)"
        let keys = plan.questions.map { Self.childKey($0.entry) }
        // Persisted reads for children or decisions the root no longer reports are stale: drop them.
        childReads[rootKey] = childReads[rootKey]?.filter { keys.contains($0.key) }
        // The cursor is the identity of the first child left unread; it is located again each visit.
        let start = childCursor[rootKey].flatMap { keys.firstIndex(of: $0) } ?? 0
        let ordered = Array(plan.questions[start...] + plan.questions[..<start])
        for (position, candidate) in ordered.enumerated() {
            switch await offeredAnswers(for: candidate, root: status, rootKey: rootKey, &budget) {
            case .failure(let failure):
                // Only this child's entries are held back; the rest of the root is still read.
                withheld.insert("input:\(id):\(candidate.entry.decisionID)")
                if failure.deferred {
                    deferred += 1
                    firstDeferred = firstDeferred ?? position
                } else {
                    failures.insert("child:\(candidate.entry.workflowRunID)")
                }
            case .success(let offered):
                items.append(NeedsYouMapper.question(candidate: candidate, root: status, state: state, names: names, offered: offered))
            }
        }
        if let recovery = plan.recovery { items.append(recovery) }
        if let firstDeferred {
            childCursor[rootKey] = keys[(start + firstDeferred) % keys.count]
        } else {
            childReads[rootKey] = nil
            childCursor[rootKey] = nil
        }
        return .ready(items, withheld: withheld, childFailures: failures)
    }

    private struct EntryFailure: Error { let deferred: Bool }

    private static func childKey(_ entry: WorkflowPendingInput) -> String { "\(entry.workflowRunID)#\(entry.decisionID)" }

    /// Structured usage-limit answers come from the source run's own `usage_limit_recovery`; a worker
    /// usage limit has none and is an ordinary free-text question. Child reads are cached for the pass.
    private func offeredAnswers(
        for candidate: NeedsYouMapper.Candidate, root: WorkflowMonitorStatus, rootKey: String, _ budget: inout Budget
    ) async -> Result<[String]?, EntryFailure> {
        var recovery = root.usageLimitRecovery
        if candidate.needsSourceRead {
            guard candidate.entry.isUsageLimit else { return .success(nil) }
            switch await childStatus(candidate.entry.workflowRunID, decision: candidate.entry.decisionID, rootKey: rootKey, &budget) {
            case .failure(let failure): return .failure(EntryFailure(deferred: failure == .deferred))
            case .success(let child): recovery = child.usageLimitRecovery
            }
        }
        guard let recovery, recovery.decisionID == candidate.entry.decisionID, !recovery.choices.isEmpty else { return .success(nil) }
        return .success(recovery.choices)
    }

    /// Persisted reads are keyed by child and decision, so a child that moved on to another decision is read again.
    private func childStatus(
        _ id: String, decision: String, rootKey: String, _ budget: inout Budget
    ) async -> Result<WorkflowMonitorStatus, ChildFailure> {
        let key = "\(id)#\(decision)"
        if let read = childReads[rootKey]?[key] { return .success(read) }
        if let read = visitReads[id] { return .success(read) }
        if visitFailures.contains(id) { return .failure(.unreadable) }
        guard budget.take() else { return .failure(.deferred) }
        if let status = try? await engine.workflowStatus(id), status.isQualified {
            childReads[rootKey, default: [:]][key] = status
            visitReads[id] = status
            return .success(status)
        }
        visitFailures.insert(id)
        return .failure(.unreadable)
    }

    // MARK: - Tasks and approvals

    private func readTasks(_ budget: inout Budget, events: inout [NeedsYouEvent], baseline: Bool) async {
        let all = taskKnown.merging(taskAccum) { _, new in new }
        // Tasks whose acquisition has not completed sort first, so unfinished work always rotates in.
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
                guard case .success(let info)? = outcomes[id] else {
                    lastVisit[key] = pass
                    apply(.unreadable, key: key, events: &events, baseline: baseline)
                    continue
                }
                let observation = await observeTask(info, &budget, capability: &capability)
                if case .deferred = observation {} else { lastVisit[key] = pass }
                apply(observation, key: key, events: &events, baseline: baseline)
            }
        }
        deferred += max(0, ordered.count - index)
    }

    private func observeTask(_ info: TaskInfo, _ budget: inout Budget, capability: inout Bool?) async -> Observation {
        let key = "task:\(info.taskID)"
        if let early = summaryOutcome(info) {
            if case .ready = early { approvalProgress[key] = nil }
            return early
        }
        var progress = approvalProgress[key] ?? ApprovalProgress()
        defer { approvalProgress[key] = progress }
        if let stop = await listRows(info, &progress, &budget) { return stop }
        if let stop = await acquireDetails(info, &progress, &budget, capability: &capability) { return stop }
        // Retained details may be passes old: re-run eligibility (deadline, ownership, capability) right before publishing.
        var items: [NeedsYouItem] = []
        for row in progress.rows {
            guard case .eligible(let request)? = progress.details[row.id] else { continue }
            switch await eligible(request, &budget, capability: &capability) {
            case .failure(let failure): return failure.observation
            case .success(let ok): if ok { items.append(NeedsYouMapper.approval(request: request, task: info)) }
            }
        }
        progress = ApprovalProgress()
        return .ready(items)
    }

    /// Decides from the approval summary alone, or nil when approvals must be listed. Uncertainty and
    /// incompleteness come first: an uncertain ledger can report zero awaiting.
    private func summaryOutcome(_ info: TaskInfo) -> Observation? {
        // An absent or malformed summary is unknown, not empty: withdraw rather than resolve.
        guard let summary = info.raw["approval_summary"]?.objectValue else { return .unreadable }
        if summary["error"] != nil || summary["interaction_state"]?.stringValue == "approval_state_uncertain" { return .unreadable }
        guard let awaiting = info.awaitingDecisionCount else { return .unreadable }
        return awaiting > 0 ? nil : .ready([])
    }

    /// Pages the task's approvals; the cursor and rows persist across passes, so a long listing always advances.
    private func listRows(_ info: TaskInfo, _ progress: inout ApprovalProgress, _ budget: inout Budget) async -> Observation? {
        while !progress.listComplete {
            guard budget.take() else { return .deferred }
            guard let page = try? await engine.approvalPage(taskID: info.taskID, cursor: progress.cursor) else {
                progress = ApprovalProgress()
                return .unreadable
            }
            for row in page.requests where row.mayBeAnsweredFromMonitor {
                // A listing that shifts between pages can repeat a request: keep the last copy, and refetch if it changed.
                if let index = progress.rows.firstIndex(where: { $0.id == row.id }) {
                    if progress.rows[index] != row { progress.details[row.id] = nil }
                    progress.rows[index] = row
                } else {
                    progress.rows.append(row)
                }
            }
            guard let next = page.nextCursor else {
                progress.cursor = nil
                progress.listComplete = true
                break
            }
            guard progress.seenCursors.insert(next).inserted else {
                progress = ApprovalProgress()
                return .unreadable
            }
            progress.cursor = next
        }
        return nil
    }

    private func acquireDetails(
        _ info: TaskInfo, _ progress: inout ApprovalProgress, _ budget: inout Budget, capability: inout Bool?
    ) async -> Observation? {
        let held = Dictionary(
            sources["task:\(info.taskID)"]?.items.compactMap { item in item.approval.map { (item.id, $0) } } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        for row in progress.rows where progress.details[row.id] == nil {
            let candidate: CallerApprovalRequest
            if let existing = held["approval:\(row.taskID):\(row.id)"], existing.revision == row.revision, existing.isSameCurrent(as: row) {
                candidate = existing
            } else {
                guard budget.take() else { return .deferred }
                guard let detail = try? await engine.approvalDetail(taskID: row.taskID, requestID: row.id) else {
                    progress = ApprovalProgress()
                    return .unreadable
                }
                candidate = detail
            }
            switch await eligible(candidate, &budget, capability: &capability) {
            case .failure(let failure): return failure.observation
            case .success(let ok): progress.details[row.id] = ok ? .eligible(candidate) : .skipped
            }
        }
        return nil
    }

    /// The shared eligibility predicate, at the time of use; reused details are re-checked for their deadline too.
    private func eligible(
        _ request: CallerApprovalRequest, _ budget: inout Budget, capability: inout Bool?
    ) async -> Result<Bool, ObservationFailure> {
        if request.interactionOwner == .caller, capability == nil {
            guard budget.take(1) else { return .failure(ObservationFailure(observation: .deferred)) }
            guard let value = try? await engine.supportsMonitorApprovalResponses() else {
                return .failure(ObservationFailure(observation: .unreadable))
            }
            capability = value
        }
        return .success(request.isEligibleForMonitorResponse(supportsCallerResponses: capability == true, now: now()))
    }

    // MARK: - Applying observations

    private func apply(_ observation: Observation, key: String, events: inout [NeedsYouEvent], baseline: Bool, countUnreadable: Bool = true) {
        switch observation {
        case .deferred:
            deferred += 1
        case .unreadable:
            attempted.insert(key)
            if countUnreadable { unreadable.insert(key) }
            sources[key, default: Source(items: [], visible: false)].visible = false
        case .unsupported:
            attempted.insert(key)
            unreadable.remove(key)
            unsupportedRoots.insert(key)
            sources[key, default: Source(items: [], visible: false)].visible = false
        case .ready(let items, let withheld, let failures):
            attempted.insert(key)
            unreadable.remove(key)
            unsupportedRoots.remove(key)
            unreadable.subtract(childFailures[key] ?? [])
            childFailures[key] = failures.isEmpty ? nil : failures
            unreadable.formUnion(failures)
            let firstReady = visitedEver.insert(key).inserted
            let previous = sources[key]
            let known = (previous?.items ?? []) + (previous?.withheld ?? [])
            let oldIDs = Set(known.map(\.id))
            let newIDs = Set(items.map(\.id))
            for id in suppressed.keys where !newIDs.contains(id) && oldIDs.contains(id) { suppressed[id] = nil }
            for item in known where !newIDs.contains(item.id) && !withheld.contains(item.id) { events.append(.resolved(item.id)) }
            // Baseline items are those first read while the launch cycle is still in progress.
            for item in items where !oldIDs.contains(item.id) && suppressed[item.id] == nil {
                events.append(.appeared(item, sourceBaseline: firstReady && baseline))
            }
            sources[key] = Source(items: items, withheld: known.filter { withheld.contains($0.id) && !newIDs.contains($0.id) }, visible: true)
        }
    }

    private func expireSuppression() {
        let cutoff = now().addingTimeInterval(-Self.suppressionSeconds)
        suppressed = suppressed.filter { $0.value > cutoff }
    }

    /// Ready after one full inventory cycle in which every known source was attempted; a source that stays
    /// unreadable still counts once attempted, so it cannot hold the launch cycle open forever.
    private func updatePhase() {
        guard phase == .loading, workflowComplete, taskComplete else { return }
        let roots = candidateRoots().map { "workflow:\($0.id)" }
        let tasks = taskKnown.keys.map { "task:\($0)" }
        if (roots + tasks).allSatisfy(attempted.contains) { phase = .ready }
    }

    // MARK: - Output

    private func output(_ events: [NeedsYouEvent]) -> Output {
        revision += 1
        let visible = sources.values.filter(\.visible).flatMap(\.items).filter { suppressed[$0.id] == nil }
        let hidden = sources.values.flatMap { $0.visible ? $0.withheld : $0.items + $0.withheld }.filter { suppressed[$0.id] == nil }
        let snapshot = NeedsYouSnapshot(
            phase: phase, items: visible.sorted(by: NeedsYouItem.ordered), unreadableSourceCount: unreadable.count,
            deferredSourceCount: deferred, workflowInputsUnsupported: !unsupportedRoots.isEmpty,
            withdrawn: hidden.sorted(by: NeedsYouItem.ordered)
        )
        return Output(revision: revision, snapshot: snapshot, events: events)
    }
}
