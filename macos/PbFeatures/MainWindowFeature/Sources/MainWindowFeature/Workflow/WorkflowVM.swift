import AppKit
import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI

// MARK: - WorkflowUseCase

@Mockable
@MainActor
protocol WorkflowUseCase: Sendable {
    func command(_ command: String, options: [String], positionals: [String]) async throws -> [String: JSONValue]
    func validate(definition: JSONValue) async throws -> [String: JSONValue]
    func save(name: String, definition: JSONValue, expectedRevision: Int) async throws -> [String: JSONValue]
    func refreshTasks() async
    var backendIDs: [String] { get }
    func modelOptions(backend: String) async -> [ModelOption]
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
    var runs: [WorkflowRunModel] = []
    var definition: [String: JSONValue] = [:] { didSet { recordEdit(name: name, definition: oldValue); scheduleValidation(); scheduleDraftPersistence() } }
    var name = "" { didSet { recordEdit(name: oldValue, definition: definition); scheduleValidation(); scheduleDraftPersistence() } }
    var loadedName = ""
    var initialLoadingID = UUID()
    var initialLoadingKind: String? { didSet { initialLoadingID = UUID() } }
    var initialLoadFailed = false
    var revision = 0
    var savedDefinition: [String: JSONValue] = [:]
    private var primaryNodeID: String?
    private(set) var selectedNodeIDs: Set<String> = []
    var selectedNodeID: String? {
        get { primaryNodeID }
        set { selectedNodeIDs = newValue.map { [$0] } ?? []; primaryNodeID = newValue }
    }

    var selectedEdgeID: String?
    var connectionSourceID: String?
    var selectedRun: WorkflowRunModel? { didSet { updateBranchSelection(); scheduleValidation(); scheduleDraftPersistence() } }
    var branchSelection = WorkflowBranchSelection()
    var selectedActivationID: String?
    var isEditing = false
    private var operationBusy = false
    var isBusy: Bool {
        get { operationBusy || builderDispatchPending }
        set { operationBusy = newValue }
    }

    var errorText: String?
    var validationDependencies: [String: JSONValue] = [:]
    var validationMessage: String?
    var repo = ""
    var prompt = ""
    var freedom = "write_in_repo"
    var instructions = ""
    var additionalAttempts = 0
    var launchAgent: [String: JSONValue] = [:]
    var overrideOrchestrator = false
    var generationAgent: [String: JSONValue] = ["backend": .string("codex")]
    var generationFallbacks: [[String: JSONValue]] = []
    var modelChoices: [String: [ModelChoiceModel]] = [:]
    var showsRunSheet = false
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
    @ObservationIgnored private var generationID = UUID()
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

    init(useCase: any WorkflowUseCase, routing: any WorkflowRouting, parallel: ParallelVM, draftStore: any WorkflowDraftStoring) {
        self.draftStore = draftStore
        self.useCase = useCase
        self.routing = routing
        self.parallel = parallel
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

    var backendIDs: [String] { useCase.backendIDs.isEmpty ? BackendStyle.known : useCase.backendIDs }
    var selectedNode: WorkflowNodeModel? { nodes.first { $0.id == selectedNodeID } }
    var selectedEdge: WorkflowEdgeModel? { edges.first { $0.id == selectedEdgeID } }
    var canSave: Bool { initialLoadingKind == nil && !initialLoadFailed && !isBusy && selectedRun == nil && hasUnsavedChanges }

    var canDiscard: Bool {
        canEditHistory && (name != loadedName
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
        let generation = UUID()
        generationID = generation
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else {
                    return
                }
                await refresh(generation: generation)
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    func didDisappear() {
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
        parallel.didDisappear()
        didSubscribe = false
    }

    func refresh(generation: UUID? = nil) async {
        reconnectBuilderSession()
        let refreshRunID = selectedRun?.id
        let loadingID = initialLoadingID
        let loadingRunID = initialLoadingKind == "run" ? selectedRun?.id : nil
        defer {
            if let loadingRunID, selectedRun?.id == loadingRunID, initialLoadingKind == "run", initialLoadingID == loadingID {
                initialLoadingKind = nil
                initialLoadFailed = selectedRun?.raw["status"]?.stringValue == nil
            }
        }
        do {
            if selectedRun == nil {
                let list = try await useCase.command("list", options: [], positionals: [])
                guard !Task.isCancelled, generation == nil || generation == generationID else { return }
                workflows = WorkflowJSON.objects(list["workflows"]).map { WorkflowRecord(raw: $0) }
            }
            guard selectedRun?.id == refreshRunID else { return }
            if let run = selectedRun {
                let response = try await runPolling.load(id: run.id, useCase: useCase)
                guard !Task.isCancelled, selectedRun?.id == run.id, initialLoadingID == loadingID,
                      generation == nil || generation == generationID else {
                          return
                      }
                selectedRun = WorkflowRunModel(raw: response["run"]?.objectValue ?? response)
                initialLoadFailed = selectedRun?.raw["status"]?.stringValue == nil
                if errorText == refreshErrorText || errorText == WorkflowRunPolling.staleDetailMessage { errorText = nil }
                refreshErrorText = nil
                updateActivityMembership()
            }
        } catch {
            guard !Task.isCancelled, selectedRun?.id == refreshRunID,
                  initialLoadingID == loadingID,
                  generation == nil || generation == generationID else { return }
            let message = Self.message(error)
            refreshErrorText = message
            errorText = message
        }
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
        perform { [weak self] in
            guard let self else {
                return
            }
            var options = ["--monitor", "--repo=\(repo)", "--prompt=\(prompt)"]
            if overrideOrchestrator {
                options += Self.candidateOptions(launchAgent)
            }
            let response = try await useCase.command("start", options: options, positionals: [loadedName])
            guard let id = response["workflow_run_id"]?.stringValue else {
                throw WorkflowUIError.missingRun
            }
            showsRunSheet = false
            initialLoadingKind = "run"
            initialLoadFailed = false
            selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string(id), "workflow_name": .string(loadedName), "definition": .object(definition)])
            isEditing = false
            await useCase.refreshTasks()
            await refresh()
        }
    }

    func selectNode(_ id: String) {
        if let source = connectionSourceID, source != id, selectedRun == nil {
            addEdge(source: source, target: id)
            connectionSourceID = nil
        }
        selectedNodeID = id
        selectedEdgeID = nil
    }

    func selectNodes(_ ids: Set<String>, primary: String? = nil) {
        let valid = ids.intersection(Set(nodes.map(\.id)))
        selectedNodeIDs = valid
        primaryNodeID = primary.flatMap { valid.contains($0) ? $0 : nil } ?? valid.sorted().first
        selectedEdgeID = nil
        connectionSourceID = nil
    }

    func toggleNode(_ id: String) {
        var selection = selectedNodeIDs
        if !selection.insert(id).inserted { selection.remove(id) }
        selectNodes(selection, primary: selection.contains(id) ? id : primaryNodeID)
    }

    func moveNodes(_ positions: [String: CGPoint]) {
        guard selectedRun == nil, !positions.isEmpty else { return }
        var entries = WorkflowJSON.objects(definition["nodes"])
        for index in entries.indices {
            guard let id = entries[index]["id"]?.stringValue, let point = positions[id] else { continue }
            entries[index]["position"] = .object(["x": .number(max(0, point.x)), "y": .number(max(0, point.y))])
        }
        let value = JSONValue.array(entries.map(JSONValue.object))
        guard definition["nodes"] != value else { return }
        definition["nodes"] = value
    }

    func selectActivation(_ id: String?) {
        selectedActivationID = id
        updateActivityMembership()
    }

    func updateNode(_ id: String, key: String, value: JSONValue?) {
        guard selectedRun == nil else { return }
        var entries = WorkflowJSON.objects(definition["nodes"])
        guard let index = entries.firstIndex(where: { $0["id"]?.stringValue == id }) else {
            return
        }
        entries[index] = WorkflowAccess.updating(entries[index], key: key, value: value)
        definition["nodes"] = .array(entries.map(JSONValue.object))
    }

    func updateEdge(_ id: String, key: String, value: JSONValue?) {
        guard selectedRun == nil else { return }
        var entries = WorkflowJSON.objects(definition["connections"])
        guard let index = entries.firstIndex(where: { $0["id"]?.stringValue == id }) else {
            return
        }
        entries[index][key] = value
        definition["connections"] = .array(entries.map(JSONValue.object))
    }

    func moveNode(_ id: String, to point: CGPoint) {
        guard selectedRun == nil else { return }
        let point = WorkflowCanvasGeometry.snapped(point)
        let position: JSONValue = .object(["x": .number(max(0, point.x)), "y": .number(max(0, point.y))])
        guard definition["nodes"]?.arrayValue?.first(where: { $0["id"]?.stringValue == id })?["position"] != position else { return }
        updateNode(id, key: "position", value: position)
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
            node["max_attempts"] = .number(3)
            node["freedom"] = .string(WorkflowAccess.defaultLevel(for: kind))
            node["branch_mode"] = .string("auto")
        }
        if type == "workflow" {
            node["workflow_ref"] = .object(["workflow_id": .string("")])
            node["orchestrator_mode"] = .string("child")
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

    func loadModels(_ backend: String) {
        guard modelChoices[backend] == nil else {
            return
        }
        Task { [weak self] in
            guard let self else {
                return
            }
            let options = await useCase.modelOptions(backend: backend)
            modelChoices[backend] = [ModelChoiceModel(id: "", title: "Default")] + options.map { ModelChoiceModel(id: $0.value, title: $0.label) }
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

    private func addEdge(source: String, target: String) {
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

    func updateActivityMembership() {
        let activations = selectedRun?.activations ?? []
        let relevant = activations.filter { ["node", "builder"].contains($0["role"]?.stringValue ?? "") }
        var latestByNode: [String: [String: JSONValue]] = [:]
        for activation in relevant { latestByNode[activation["node_id"]?.stringValue ?? "builder"] = activation }
        let visible = selectedActivationID.map { selected in relevant.filter { $0["id"]?.stringValue == selected } } ?? Array(latestByNode.values)
        let tasks = relevant.flatMap { WorkflowJSON.objects($0["tasks"]).compactMap { $0["task_id"]?.stringValue } }
        let focused = Set(visible.flatMap { WorkflowJSON.objects($0["tasks"]).compactMap { $0["task_id"]?.stringValue } })
        var titles: [String: String] = [:]
        for activation in relevant {
            let nodeID = activation["node_id"]?.stringValue ?? ""
            let title = nodes.first { $0.id == nodeID }?.name ?? "Workflow builder"
            let index = relevant.filter { $0["node_id"]?.stringValue == nodeID }.firstIndex { $0["id"] == activation["id"] }.map { $0 + 1 } ?? 1
            let fallbackIndices = WorkflowExecutionAttempts.fallbackIndices(activation)
            for task in WorkflowJSON.objects(activation["tasks"]) {
                if let id = task["task_id"]?.stringValue {
                    let fallback = fallbackIndices[id] ?? 0
                    titles[id] = "\(title) · \(index)\(fallback > 0 ? " · Fallback \(fallback)" : "")"
                }
            }
        }
        var seen = Set<String>()
        parallel.setWorkflowTaskIDs(tasks.filter { seen.insert($0).inserted }, focusedTaskIDs: focused, titles: titles)
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
    var errorDescription: String? { "Polybridge returned no workflow run identifier." }
}
