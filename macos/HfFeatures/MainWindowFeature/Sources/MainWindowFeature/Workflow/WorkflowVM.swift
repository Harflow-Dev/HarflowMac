import AppKit
import Combine
import Foundation
import HfCommon
import HfRepository
import HfUI
import Mockable
import MonitorCore

// MARK: - WorkflowUseCase

@Mockable
@MainActor
protocol WorkflowUseCase: Sendable {
    func command(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue]
    func validate(definition: JSONValue) async throws -> [String: JSONValue]
    func save(name: String, definition: JSONValue, expectedRevision: Int, expectedWorkflowID: String?) async throws -> [String: JSONValue]
    func artifactPage(runID: String, executionID: String, cursor: String?) async -> Result<WorkflowArtifactPage, ToolError>
    func refreshTasks() async
    var backendIDs: [String] { get }
    var agentUsageSnapshot: AgentUsageSnapshot { get }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never>
    func recordAgentUsage(_ identity: AgentUsageIdentity, acknowledgementID: String) async
    var callerApprovalBackends: Set<String> { get }
    func modelOptions(backend: String) async -> [ModelOption]
}

extension WorkflowUseCase {
    var agentUsageSnapshot: AgentUsageSnapshot { .init() }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { Just(.init()).eraseToAnyPublisher() }
    func recordAgentUsage(_: AgentUsageIdentity, acknowledgementID _: String) async {}
    var callerApprovalBackends: Set<String> { [] }
    func artifactPage(runID _: String, executionID _: String, cursor _: String?) async -> Result<WorkflowArtifactPage, ToolError> {
        .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Artifact metadata unavailable"))
    }
}

// MARK: - WorkflowRouting

@Mockable
@MainActor
protocol WorkflowRouting: ParallelRouting {
    func selectTask(_ taskID: String)
    func chooseDirectory() async -> String?
    func didSaveWorkflow(name: String)
    func openWorkflowEditor(name: String?)
    func openWorkflowRun(id: String)
}

// MARK: - WorkflowVM

@Observable
@MainActor
final class WorkflowVM: WorkflowViewModel {
    var workflows: [WorkflowRecord] = []
    var hasLoadedWorkflowList = false
    var runs: [WorkflowRunModel] = []
    var definition: [String: JSONValue] = [:] { didSet { recordEdit(name: name, definition: oldValue); scheduleValidation(); scheduleDraftPersistence() } }
    var name = "" { didSet { recordEdit(name: oldValue, definition: definition); scheduleValidation(); scheduleDraftPersistence() } }
    var loadedName = "" { didSet { if loadedName != oldValue { scheduleLaunchPreview() } } }
    var initialLoadingID = UUID()
    var initialLoadingKind: String? { didSet { initialLoadingID = UUID() } }
    var initialLoadFailed = false
    var revision = 0
    var savedDefinition: [String: JSONValue] = [:] { didSet { if savedDefinition != oldValue { scheduleLaunchPreview() } } }
    var primaryNodeID: String?
    var selectedNodeIDs: Set<String> = []
    var selectedNodeID: String? {
        get { primaryNodeID }
        set {
            guard primaryNodeID != newValue else { return }
            selectedNodeIDs = newValue.map { [$0] } ?? []
            primaryNodeID = newValue
            selectedActivationID = nil
            scheduleRunSidebar()
        }
    }

    var selectedEdgeID: String?
    var connectionSourceID: String?
    var selectedRun: WorkflowRunModel? { didSet {
        updateBranchSelection(); scheduleValidation(); scheduleDraftPersistence()
        if selectedRun?.id != oldValue?.id { selectedActivationID = nil }
        if selectedRun != oldValue { scheduleRunSidebar() }
    } }
    var branchSelection = WorkflowBranchSelection()
    var selectedActivationID: String?
    var isEditing = false
    private var operationBusy = false
    var isBusy: Bool {
        get { operationBusy || builderDispatchPending }
        set { operationBusy = newValue }
    }

    var errorText: String?
    var readFailures: [String: String] = [:]
    @ObservationIgnored var readRetries: [String: AlertAction] = [:]
    var currentReadFailureSource: String?
    var readFailureText: String? { errorText.flatMap { readFailures.values.contains($0) ? $0 : nil } }
    var validationDependencies: [String: JSONValue] = [:]
    var nativeSubagentsAvailable = false
    var artifacts = WorkflowArtifactModel()
    @ObservationIgnored var artifactTask: Task<Void, Never>?
    @ObservationIgnored var artifactGeneration = UUID()
    var runSidebar = WorkflowRunSidebarPresentation()
    var selectedActivity: ParallelVM?
    @ObservationIgnored var sidebarTask: Task<Void, Never>?
    @ObservationIgnored var sidebarGeneration = UUID()
    @ObservationIgnored var activityCache: [String: ParallelVM] = [:]
    @ObservationIgnored var activityRunID: String?
    @ObservationIgnored var runGraphVisible = true
    var nativeActivity: WorkflowNativeActivityModel?
    @ObservationIgnored var nativeActivityTask: Task<Void, Never>?

    var editorConflict: String?
    var checkingEditorBaseline = false
    var missingReferences: [[String: JSONValue]] = []
    var missingReferencesTruncated = false
    var validationMessage: String?
    var repo = "" { didSet { if repo != oldValue { scheduleLaunchPreview() } } }
    var prompt = ""
    var goal = ""
    var freedom = "write_in_repo"
    var instructions = ""
    var additionalAttempts = 0
    var launchAgent: [String: JSONValue] = [:] { didSet { if launchAgent != oldValue { scheduleLaunchPreview() } } }
    var overrideOrchestrator = false { didSet { if overrideOrchestrator != oldValue { scheduleLaunchPreview() } } }
    var generationAgent: [String: JSONValue] = ["backend": .string("codex")]
    var generationFallbacks: [[String: JSONValue]] = []
    var modelChoices: [String: [ModelChoiceModel]] = [:]
    var agentUsageSnapshot = AgentUsageSnapshot()
    @ObservationIgnored private var usageSubscription: AnyCancellable?
    @ObservationIgnored private var modelTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var modelGeneration = UUID()
    var showsRunSheet = false { didSet { if showsRunSheet != oldValue { scheduleLaunchPreview() } } }
    var launchPreview: WorkflowPermissionPreview?
    var launchPreviewMessage: String?
    @ObservationIgnored var launchPreviewTask: Task<Void, Never>?
    @ObservationIgnored var launchPreviewID = UUID()
    var showsGenerateSheet = false
    var isRefining = false
    var refinementContext: WorkflowRefinementContext?
    var appliedProposalIDs: Set<String> = []
    var parallel: ParallelVM

    @ObservationIgnored let useCase: any WorkflowUseCase
    @ObservationIgnored let draftStore: any WorkflowDraftStoring
    var builderDispatchPending = false
    @ObservationIgnored var draftWriteTask: Task<Void, Never>?
    @ObservationIgnored var draftKey: String?
    @ObservationIgnored var draftPersistenceSuspended = false
    @ObservationIgnored let routing: any WorkflowRouting
    @ObservationIgnored private var terminationSubscription: AnyCancellable?
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored var refreshErrorText: String?
    @ObservationIgnored var runPolling = WorkflowRunPolling()
    @ObservationIgnored var generationID = UUID()
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored var editorReadTask: Task<Void, Never>?
    @ObservationIgnored var editorLoadID = UUID()
    @ObservationIgnored var pendingEditorName: String?
    @ObservationIgnored var draftID = UUID()
    @ObservationIgnored var validationTask: Task<Void, Never>?
    @ObservationIgnored var validationID = UUID()
    var canonicalValidationDefinition: [String: JSONValue]?
    var canonicalValidationSource: [String: JSONValue]?
    @ObservationIgnored var validatedDefinition: [String: JSONValue]?
    @ObservationIgnored var validationSuspended = false
    @ObservationIgnored private var operation: Task<Void, Never>?

    @ObservationIgnored private let routesStartedRun: Bool
    /// Whether anyone can see the Monitor — pauses this screen's poll while the window is hidden,
    /// with the showing window waking it for an immediate refresh.
    @ObservationIgnored private let visibility: any MonitorVisibility
    /// The poll's 2 s wait runs on the scheduler seam so tests fire it directly, never a real timer.
    @ObservationIgnored private let scheduler: any Scheduling

    init(useCase: any WorkflowUseCase, routing: any WorkflowRouting, parallel: ParallelVM,
         draftStore: any WorkflowDraftStoring, routesStartedRun: Bool = false,
         visibility: any MonitorVisibility, scheduler: any Scheduling) {
        self.routesStartedRun = routesStartedRun
        self.draftStore = draftStore
        self.useCase = useCase
        self.routing = routing
        self.parallel = parallel
        self.visibility = visibility
        self.scheduler = scheduler
        self.agentUsageSnapshot = useCase.agentUsageSnapshot
        parallel.setWorkflowTaskIDs([])
    }

    private var displayedDefinition: [String: JSONValue] {
        if let run = selectedRun { return run.definition }
        return definition
    }

    var nodes: [WorkflowNodeModel] { WorkflowJSON.nodes(displayedDefinition) }
    var edges: [WorkflowEdgeModel] {
        let raw = WorkflowJSON.edges(displayedDefinition)
        guard selectedRun == nil else { return raw }
        let canonical = canonicalValidationSource.map { WorkflowRetryMetadata.topology($0) == WorkflowRetryMetadata.topology(definition) } == true
            ? canonicalValidationDefinition : nil
        let flags = Dictionary(uniqueKeysWithValues: WorkflowJSON.edges(canonical ?? [:]).map { ($0.id, $0.isBackward) })
        return raw.map { edge in
            var mapped = edge.raw
            mapped["backward"] = .bool(flags[edge.id] ?? false)
            return WorkflowEdgeModel(raw: mapped)
        }
    }

    // Only the small available harness menu is ordered here; the draft remains untouched.
    var backendIDs: [String] { agentUsageSnapshot.rankedBackends(useCase.backendIDs.isEmpty ? BackendStyle.known : useCase.backendIDs) }
    var selectedEdge: WorkflowEdgeModel? { edges.first { $0.id == selectedEdgeID } }
    var canSave: Bool {
        initialLoadingKind == nil && !initialLoadFailed && !checkingEditorBaseline
            && editorConflict == nil && !isBusy && selectedRun == nil && hasUnsavedChanges
    }

    var canDiscard: Bool {
        !checkingEditorBaseline && canEditHistory && (name != loadedName
            || !WorkflowDraftEquality.matches(definition, loadedName.isEmpty ? Self.starterDefinition() : savedDefinition))
    }

    var canUndo: Bool { canEditHistory && !editHistory.isEmpty }
    var canEditHistory: Bool {
        initialLoadingKind == nil && !initialLoadFailed && selectedRun == nil && !isBusy
            && !(isRefining && showsGenerateSheet) && refinementContext == nil
    }

    var editHistory: [WorkflowEditSnapshot] = []
    var editHistorySuspended = false
    var nodeDragSnapshot: WorkflowEditSnapshot?

    var hasUnsavedChanges: Bool { loadedName.isEmpty || name != loadedName || !WorkflowDraftEquality.matches(definition, savedDefinition) }

    func didAppear() {
        guard !didSubscribe else {
            return
        }
        didSubscribe = true
        applyUsageSnapshot(useCase.agentUsageSnapshot)
        usageSubscription = useCase.agentUsagePublisher().receive(on: DispatchQueue.main).sink { [weak self] snapshot in
            self?.applyUsageSnapshot(snapshot)
        }
        if selectedRun?.raw["status"]?.stringValue == nil, selectedRun != nil {
            initialLoadingKind = "run"
            initialLoadFailed = false
        }
        if let builderSession { restoreBuilderSession(builderSession) }
        terminationSubscription = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification).sink { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.persistDraft() }
        }
        if let pendingEditorName {
            self.pendingEditorName = nil
            selectWorkflow(WorkflowRecord(raw: ["name": .string(pendingEditorName)]))
        }
        validationSuspended = false
        scheduleValidation()
        parallel.didAppear()
        scheduleRunSidebar()
        let generation = UUID()
        generationID = generation
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await refresh(generation: generation)
                // B1: full 2 s cadence while the window is visible; a hidden window parks the poll
                // in `waitForMainWindowVisible()`, and the showing window wakes it for the next
                // pass — the immediate refresh on show.
                do {
                    if visibility.mainWindowVisible {
                        try await scheduler.wait(for: 2)
                    } else {
                        await visibility.waitForMainWindowVisible()
                        try Task.checkCancellation()
                    }
                } catch { return }
            }
        }
    }

    func didDisappear() {
        usageSubscription = nil
        for task in modelTasks.values { task.cancel() }
        modelTasks.removeAll()
        modelGeneration = UUID()

        sidebarTask?.cancel()
        sidebarTask = nil
        sidebarGeneration = UUID()
        for activity in activityCache.values { activity.didDisappear() }
        activityCache.removeAll()
        selectedActivity = nil
        clearArtifacts()
        if initialLoadingKind == "editor", let key = draftKey, key.hasPrefix("saved:") {
            pendingEditorName = String(key.dropFirst(6))
        }
        if initialLoadingKind != nil { initialLoadFailed = true }
        initialLoadingKind = nil
        persistDraft()
        resetEditHistory()
        terminationSubscription = nil
        editorReadTask?.cancel()
        editorReadTask = nil
        editorLoadID = UUID()
        validationSuspended = true
        validationTask?.cancel()
        validationTask = nil
        validationID = UUID()
        validatedDefinition = nil
        poll?.cancel()
        poll = nil
        generationID = UUID()
        launchPreviewTask?.cancel()
        launchPreviewTask = nil
        launchPreviewID = UUID()
        launchPreview = nil
        nativeActivityTask?.cancel()
        nativeActivityTask = nil
        parallel.didDisappear()
        didSubscribe = false
    }

    func duplicate() {
        guard selectedRun == nil else {
            return
        }
        guard draftKey != "new", canUseDraftSlot("new") else {
            if draftKey == "new" { errorText = "Save this new workflow before creating a copy." }
            return
        }
        persistDraft()
        resetEditHistory()
        draftKey = "new"
        editorReadTask?.cancel()
        editorLoadID = UUID()
        editorConflict = nil
        checkingEditorBaseline = false
        draftPersistenceSuspended = true
        draftID = UUID()
        name += "-copy"
        loadedName = ""
        revision = 0
        savedDefinition = [:]
        draftPersistenceSuspended = false
        persistDraft()
    }

    func deleteWorkflow() {
        let target = loadedName
        guard !target.isEmpty else {
            return
        }
        publishDialog("Delete workflow ‘\(target)’?", description: "Existing run snapshots remain available.") {
            AlertAction(title: "Delete", role: .destructive) { [weak self] in
                self?.perform { [weak self] in
                    guard let self else {
                        return
                    }
                    _ = try await useCase.command("delete", options: [], positionals: [target])
                    routing.openWorkflowEditor(name: nil)
                    await refresh()
                }
            }
        }
    }

    func chooseRepo() {
        Task { [weak self] in
            guard let self, let chosen = await routing.chooseDirectory() else {
                return
            }
            repo = chosen
        }
    }

    func prepareLaunch() {
        launchAgent = definition["orchestrator"]?.objectValue ?? ["backend": .string("codex")]
        overrideOrchestrator = false
        showsRunSheet = true
    }

    func start() {
        guard !loadedName.isEmpty else {
            errorText = "Save the workflow before running it."; return
        }
        guard !hasUnsavedChanges else {
            errorText = "Save your changes before running this workflow."; return
        }
        guard let preview = launchPreview, canStartWithPreview else {
            errorText = "Wait for the orchestrator permission preview before running."
            return
        }
        guard goal.utf8.count <= 65_536 else {
            errorText = "Goal must be at most 64 KiB of UTF-8 text."
            return
        }
        let capturedName = loadedName
        let capturedDefinition = definition
        let candidate = overrideOrchestrator ? launchAgent : (capturedDefinition["orchestrator"]?.objectValue ?? [:])
        let capturedIdentity = AgentUsageIdentity(backend: candidate["backend"]?.stringValue ?? "", model: candidate["model"]?.stringValue)
        let goalOptions = goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["--goal=\(goal)"]
        let capturedOptions = goalOptions + launchPreviewOptions + ["--monitor", "--prompt=\(prompt)", "--expected-preview-hash=\(preview.hash)"]
        perform { [weak self] in
            guard let self else { return }
            let options = capturedOptions
            let response: [String: JSONValue]
            do {
                response = try await useCase.command("start", options: options, positionals: [capturedName])
            } catch {
                scheduleLaunchPreview()
                throw error
            }
            guard let id = response["workflow_run_id"]?.stringValue, !id.isEmpty else {
                throw WorkflowUIError.missingRun
            }
            await useCase.recordAgentUsage(capturedIdentity, acknowledgementID: "workflow:" + id)
            showsRunSheet = false
            initialLoadingKind = "run"
            initialLoadFailed = false
            selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string(id), "workflow_name": .string(capturedName),
                                                 "definition": .object(capturedDefinition)])
            isEditing = false
            if routesStartedRun {
                routing.openWorkflowRun(id: id)
                await useCase.refreshTasks()
                return
            }
            await useCase.refreshTasks()
            await refresh()
        }
    }

    func addNode(_ kind: String, at point: CGPoint? = nil) {
        guard selectedRun == nil else { return }
        if kind == "parallel_group" { addParallelGroup(at: point); return }
        var entries = WorkflowJSON.objects(definition["nodes"])
        guard !["start", "end"].contains(kind) || !entries.contains(where: { $0["type"]?.stringValue == kind }) else { return }
        let id = UUID().uuidString.lowercased()
        let type = ["start", "join", "end", "workflow"].contains(kind) ? kind : "agent"
        let point = WorkflowCanvasGeometry.snapped(point ?? CGPoint(x: 80 + (entries.count % 4) * 250, y: 200 + (entries.count / 4) * 130))
        var node: [String: JSONValue] = [
            "id": .string(id),
            "title": .string(WorkflowRole.title(kind)),
            "type": .string(type),
            "branch_mode": .string("auto"),
            "position": .object(["x": .number(point.x), "y": .number(point.y)])
        ]
        if type == "agent" {
            node["role"] = .string(kind)
            node["instructions"] = .string("")
            var candidate = WorkflowCandidateSettings.make(backend: backendIDs.first ?? "codex")
            candidate["fallbacks"] = .array([])
            node["agent"] = .object(candidate)
            node["session_mode"] = .string("agent_decides")
            node["execution_mode"] = .string("prefer_subagent")
            node["max_attempts"] = .number(3)
            node["freedom"] = .string(WorkflowAccess.defaultLevel(for: kind))
            node["branch_mode"] = .string("auto")
        }
        if type == "workflow" {
            node["workflow_ref"] = .object(["workflow_id": .string("")])
            node["orchestrator_mode"] = .string("child")
            node["child_session_policy"] = .string("agent_decides")
            node["instructions"] = .string("")
            node["max_attempts"] = .number(3)
            node["optional"] = .bool(false)
            definition["routing_mode"] = .string("explicit")
        }
        entries.append(node)
        definition["nodes"] = .array(entries.map(JSONValue.object))
        selectNode(id)
    }

    func deleteSelected() {
        guard selectedRun == nil else { return }
        if deleteStandaloneSelection() { return }
        if let id = selectedEdgeID {
            definition["connections"] = .array(WorkflowJSON.objects(definition["connections"])
.filter { $0["id"]?.stringValue != id }
                .map(JSONValue.object))
            selectedEdgeID = nil
        } else if !selectedNodeIDs.isEmpty {
            let removed = selectedNodeIDs
            var updated = definition
            updated["nodes"] = .array(WorkflowJSON.objects(definition["nodes"]).filter { !removed.contains($0["id"]?.stringValue ?? "") }.map(JSONValue.object))
            updated["connections"] = .array(WorkflowJSON.objects(definition["connections"])
                .filter { !removed.contains($0["source"]?.stringValue ?? "") && !removed.contains($0["target"]?.stringValue ?? "") }
                .map(JSONValue.object))
            definition = updated
            selectedNodeID = nil
            if let source = connectionSourceID, removed.contains(source) { connectionSourceID = nil }
        }
    }

    private func applyUsageSnapshot(_ snapshot: AgentUsageSnapshot) {
        guard agentUsageSnapshot != snapshot else { return }
        agentUsageSnapshot = snapshot
        let loaded = Set(modelChoices.keys).union(modelTasks.keys)
        for task in modelTasks.values { task.cancel() }
        modelTasks.removeAll()
        modelGeneration = UUID()
        for backend in loaded { requestModels(backend) }
    }

    func loadModels(_ backend: String) {
        guard modelChoices[backend] == nil else { return }
        requestModels(backend)
    }

    private func requestModels(_ backend: String) {
        guard modelTasks[backend] == nil else { return }
        let generation = modelGeneration
        modelTasks[backend] = Task { [weak self, useCase] in
            let options = await useCase.modelOptions(backend: backend)
            let usage = useCase.agentUsageSnapshot
            let ranked = await Task.detached { usage.rankedModels(options, backend: backend) }.value
            guard !Task.isCancelled, let self, modelGeneration == generation else { return }
            let choices = [ModelChoiceModel(id: "", title: "Default")] + ranked.map { ModelChoiceModel(id: $0.value, title: $0.label) }
            if modelChoices[backend] != choices { modelChoices[backend] = choices }
            modelTasks[backend] = nil
        }
    }

    func nodeStatus(_ id: String) -> String {
        guard let run = selectedRun else {
            return "pending"
        }
        if branchSelection.excludedNodeIDs.contains(id) { return "not_selected" }
        if let status = run.activations
.last(where: {
            $0["node_id"]?.stringValue == id && $0["role"]?.stringValue == "node" && branchSelection.includes($0, nodeID: id)
        })?["status"]?.stringValue {
            return status
        }
        if let node = nodes.first(where: { $0.id == id }) {
            if let status = WorkflowParallelGroup.status(of: node, run: run) { return status }
            if node.type == "start", !run.activations.isEmpty {
                return "completed"
            }
            if node.type == "end", run.status == "completed" {
                return "completed"
            }
        }
        if run.raw["pending"]?.arrayValue?.contains(where: { $0["node_id"]?.stringValue == id }) == true {
            return "waiting"
        }
        return run.status == "completed" ? "skipped" : "pending"
    }

    func nodeAttempt(_ id: String) -> Int {
        if branchSelection.excludedNodeIDs.contains(id) { return 0 }
        let executions = selectedRun?.activations.filter {
            $0["node_id"]?.stringValue == id && $0["role"]?.stringValue == "node" && branchSelection.includes($0, nodeID: id)
        } ?? []
        return executions.last?["attempt_in_visit"]?.intValue ?? executions.count
    }

    func addEdge(source: String, target: String) {
        guard source != target, let sourceNode = nodes.first(where: { $0.id == source }), sourceNode.type != "end",
              let targetNode = nodes.first(where: { $0.id == target }), targetNode.type != "start" else { return }
        var entries = WorkflowJSON.objects(definition["connections"])
        guard !entries.contains(where: { $0["source"]?.stringValue == source && $0["target"]?.stringValue == target }) else { return }
        entries.append([
            "id": .string(UUID().uuidString.lowercased()),
            "source": .string(source),
            "target": .string(target),
            "condition": .string(""),
            "default": .bool(false),
            "backward": .bool(false)
        ])
        definition["connections"] = .array(entries.map(JSONValue.object))
    }

    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard !operationBusy else {
            return
        }
        isBusy = true
        errorText = nil
        operation = Task { [weak self] in
            do { try await work() } catch { self?.errorText = Self.message(error) }
            self?.isBusy = false
        }
    }

}

// MARK: - WorkflowUIError

enum WorkflowUIError: LocalizedError {
    case missingRun
    var errorDescription: String? { "Harflow returned no workflow run identifier." }
}
