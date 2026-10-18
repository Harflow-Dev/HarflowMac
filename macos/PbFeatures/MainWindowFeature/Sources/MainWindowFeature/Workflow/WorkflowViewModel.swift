import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - WorkflowViewModel

@MainActor
protocol WorkflowViewModel: ViewModel {
    var workflows: [WorkflowRecord] { get }
    var runs: [WorkflowRunModel] { get }
    var definition: [String: JSONValue] { get set }
    var name: String { get set }
    var loadedName: String { get }
    var revision: Int { get }
    var selectedNodeID: String? { get set }
    var selectedNodeIDs: Set<String> { get }
    var selectedEdgeID: String? { get set }
    var connectionSourceID: String? { get set }
    var selectedRun: WorkflowRunModel? { get }
    var selectedActivationID: String? { get }
    var isEditing: Bool { get }
    var isBusy: Bool { get }
    var initialLoadingKind: String? { get }
    var initialLoadFailed: Bool { get }
    var errorText: String? { get }
    var readFailureText: String? { get }
    func retryReadFailure()
    var editorConflict: String? { get }
    var missingReferences: [[String: JSONValue]] { get }
    var missingReferencesTruncated: Bool { get }
    func preserveDraftAndReload()
    func replaceMissingReferences(_ target: String, with replacement: String)
    var validationMessage: String? { get }
    var validationDependencies: [String: JSONValue] { get }
    var nativeSubagentsAvailable: Bool { get }
    var artifacts: WorkflowArtifactModel { get }
    func prepareArtifacts(runID: String, executionID: String)
    func loadArtifacts()
    var nativeActivity: WorkflowNativeActivityModel? { get }
    var launchPreview: WorkflowPermissionPreview? { get }
    var launchPreviewMessage: String? { get }
    var canStartWithPreview: Bool { get }
    var branchSelection: WorkflowBranchSelection { get }
    var repo: String { get set }
    var prompt: String { get set }
    var goal: String { get set }
    func reviseGoal(_ goal: String, runID: String, expectedRevision: Int)
    var freedom: String { get set }
    var instructions: String { get set }
    var additionalAttempts: Int { get set }
    var launchAgent: [String: JSONValue] { get set }
    var overrideOrchestrator: Bool { get set }
    var generationAgent: [String: JSONValue] { get set }
    var generationFallbacks: [[String: JSONValue]] { get set }
    var modelChoices: [String: [ModelChoiceModel]] { get }
    var showsRunSheet: Bool { get set }
    var showsGenerateSheet: Bool { get set }
    var isRefining: Bool { get }
    var canReturnToCanvas: Bool { get }
    var parallel: ParallelVM { get }
    var nodes: [WorkflowNodeModel] { get }
    var edges: [WorkflowEdgeModel] { get }
    var backendIDs: [String] { get }
    var selectedNode: WorkflowNodeModel? { get }
    var selectedEdge: WorkflowEdgeModel? { get }
    var canSave: Bool { get }
    var canDiscard: Bool { get }
    var canUndo: Bool { get }
    var hasUnsavedChanges: Bool { get }
    func didAppear()
    func didDisappear()
    func selectWorkflow(_ workflow: WorkflowRecord)
    func selectRun(_ run: WorkflowRunModel)
    func openOwnerTask(_ id: String)
    func openRun(_ id: String)
    func newWorkflow()
    func openWorkflowEditor(_ name: String)
    func discardChanges()
    func undoWorkflowEdit()
    func beginNodeDrag()
    func endNodeDrag()
    func save()
    func duplicate()
    func deleteWorkflow()
    func chooseRepo()
    func prepareLaunch()
    func start()
    func generate()
    func prepareGeneration(refining: Bool)
    func returnToCanvas()
    func applyAgentProposal()
    func control(_ command: String)
    func control(_ command: String, allowOptionalReviewSkip: Bool)
    func continueWithOneMoreRetry()
    func selectNodes(_ ids: Set<String>, primary: String?)
    func toggleNode(_ id: String)
    func moveNodes(_ positions: [String: CGPoint])
    func selectNode(_ id: String)
    func selectActivation(_ id: String?)
    func updateNode(_ id: String, key: String, value: JSONValue?)
    func updateEdge(_ id: String, key: String, value: JSONValue?)
    func moveNode(_ id: String, to point: CGPoint)
    func addNode(_ kind: String, at point: CGPoint?)
    func copySelectedNodes()
    func pasteNodes()
    func deleteSelected()
    func loadModels(_ backend: String)
    func nodeStatus(_ id: String) -> String
    func nodeAttempt(_ id: String) -> Int
}

extension WorkflowViewModel {
    var artifacts: WorkflowArtifactModel { WorkflowArtifactModel() }
    func prepareArtifacts(runID _: String, executionID _: String) {}
    func loadArtifacts() {}
    var goal: String { get { "" } set { _ = newValue } }
    func reviseGoal(_: String, runID _: String, expectedRevision _: Int) {}
    var readFailureText: String? { nil }
    func retryReadFailure() {}
    func control(_ command: String, allowOptionalReviewSkip: Bool) {
        // Preview and other conformers that do not support this action never grant consent.
        guard !allowOptionalReviewSkip else { return }
        control(command)
    }
}

// MARK: - WorkflowViewModel recovery defaults

extension WorkflowViewModel {
    var editorConflict: String? { nil }
    var missingReferences: [[String: JSONValue]] { [] }
    var missingReferencesTruncated: Bool { false }
    func preserveDraftAndReload() {}
    func replaceMissingReferences(_: String, with _: String) {}
}
