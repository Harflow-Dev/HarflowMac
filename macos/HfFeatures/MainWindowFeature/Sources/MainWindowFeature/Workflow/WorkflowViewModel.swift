import HfCommon
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowViewModel

@MainActor
protocol WorkflowViewModel: ViewModel {
    var steering: WorkflowSteeringPresentation { get }
    var steeringAuthority: WorkflowSteeringAuthority? { get }
    var steeringHeaderHold: Bool? { get }
    var steeringRevalidating: Bool { get }
    var steeringDraft: String { get set }
    var steeringOwnsComposer: Bool { get }
    var steeringFailedQueue: Bool { get }
    func submitSteering(_ text: String)
    func submitSteering(_ text: String, authority: WorkflowSteeringAuthority?)
    func dismissSteering(authority: WorkflowSteeringAuthority?)
    func openSteeringNeedsYou(authority: WorkflowSteeringAuthority?)
    func dismissSteering()
    func openSteeringNeedsYou()
    var qualificationCards: [QualificationCard] { get }
    func didTapQualification()
    var workflows: [WorkflowRecord] { get }
    var hasLoadedWorkflowList: Bool { get }
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
    var deleteFailureText: String? { get }
    var canDeleteWorkflow: Bool { get }
    var readFailureText: String? { get }
    func retryReadFailure()
    var editorConflict: String? { get }
    var missingReferences: [[String: JSONValue]] { get }
    var missingReferencesTruncated: Bool { get }
    func preserveDraftAndReload()
    func replaceMissingReferences(_ target: String, with replacement: String)
    var validationMessage: String? { get }
    var validationState: WorkflowValidationState { get }
    var validationDependencies: [String: JSONValue] { get }
    var nativeSubagentsAvailable: Bool { get }
    var artifacts: WorkflowArtifactModel { get }
    func prepareArtifacts(runID: String, executionID: String)
    func loadArtifacts()
    var nativeActivity: WorkflowNativeActivityModel? { get }
    var runSidebar: WorkflowRunSidebarPresentation { get }
    var selectedActivity: ParallelVM? { get }
    func setRunGraphVisible(_ visible: Bool)
    var launchPreview: WorkflowPermissionPreview? { get }
    var launchPreviewMessage: String? { get }
    var canStartWithPreview: Bool { get }
    var branchSelection: WorkflowBranchSelection { get }
    var repo: String { get set }
    var prompt: String { get set }
    var goal: String { get set }
    func reviseGoal(_ goal: String, runID: String, expectedRevision: Int)
    /// The shared unsent goal revision, nil while no goal block is being edited.
    var goalDraft: WorkflowGoalDraft? { get }
    /// The last failed goal save's message.
    var goalRevisionError: String? { get }
    /// The revision a lost goal-revision race was submitted against.
    var goalRaceExpectedRevision: Int? { get }
    func beginGoalDraft(run: WorkflowRunModel)
    func updateGoalDraft(_ text: String)
    func cancelGoalDraft()
    var freedom: String { get set }
    var interactionOutcome: WorkflowInteractionReceipt? { get }
    var interactionSavedDraft: String? { get }
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
    var callerApprovalBackends: Set<String> { get }
    /// Engine-reported run-option controls per harness; empty until the catalog is known.
    var backendControls: [String: BackendControls] { get }
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
    var activityMessageTarget: WorkflowActivityMessageTarget { get }
    var activityMessageItems: [WorkMessageQueue.Item] { get }
    var messageNotes: [String: String] { get }
    var activityMessageReadError: String? { get }
    /// True once the runtime is known not to support queued messaging; the node pane composers then lock bare.
    var messagingUnsupported: Bool { get }
    func refreshActivityMessageState() async
    func submitActivityMessage(_ text: String, now: Bool) -> Bool
    func cancelActivityMessage(_ messageID: String)
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
    var steering: WorkflowSteeringPresentation { .init() }
    var steeringAuthority: WorkflowSteeringAuthority? { nil }
    var steeringHeaderHold: Bool? { nil }
    var steeringRevalidating: Bool { false }
    func submitSteering(_: String, authority _: WorkflowSteeringAuthority?) {}
    func dismissSteering(authority _: WorkflowSteeringAuthority?) {}
    func openSteeringNeedsYou(authority _: WorkflowSteeringAuthority?) {}
    var steeringDraft: String { get { "" } set { _ = newValue } }
    var steeringOwnsComposer: Bool { false }
    var steeringFailedQueue: Bool { false }
    func submitSteering(_: String) {}
    func dismissSteering() {}
    func openSteeringNeedsYou() {}
    var deleteFailureText: String? { nil }
    var canDeleteWorkflow: Bool {
        isEditing && !loadedName.isEmpty && !isBusy && selectedRun == nil
            && initialLoadingKind == nil && !initialLoadFailed && !(isRefining && showsGenerateSheet)
    }

    var activityMessageTarget: WorkflowActivityMessageTarget { .resolve(run: selectedRun, sidebar: runSidebar) }
    var activityMessageItems: [WorkMessageQueue.Item] { [] }
    var messageNotes: [String: String] { [:] }
    var activityMessageBubbles: [WorkMessageBubble] {
        WorkMessageBubble.applying(WorkMessageBubble.project(items: activityMessageItems), notes: messageNotes)
    }

    var activityMessageReadError: String? { nil }
    var messagingUnsupported: Bool { false }
    func refreshActivityMessageState() async {}
    func submitActivityMessage(_: String, now _: Bool) -> Bool { false }
    func cancelActivityMessage(_: String) {}
    var runSidebar: WorkflowRunSidebarPresentation { .init() }
    var selectedActivity: ParallelVM? { nil }
    func setRunGraphVisible(_: Bool) {}
    var artifacts: WorkflowArtifactModel { WorkflowArtifactModel() }
    func prepareArtifacts(runID _: String, executionID _: String) {}
    func loadArtifacts() {}
    var goal: String { get { "" } set { _ = newValue } }
    func reviseGoal(_: String, runID _: String, expectedRevision _: Int) {}
    var goalDraft: WorkflowGoalDraft? { nil }
    var goalRevisionError: String? { nil }
    var goalRaceExpectedRevision: Int? { nil }
    func beginGoalDraft(run _: WorkflowRunModel) {}
    func updateGoalDraft(_: String) {}
    func cancelGoalDraft() {}
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

@MainActor
extension WorkflowViewModel {
    var callerApprovalBackends: Set<String> { [] }
    var backendControls: [String: BackendControls] { [:] }
}

extension WorkflowViewModel {
    var validationState: WorkflowValidationState { .inactive }
    var qualificationCards: [QualificationCard] { [] }
    func didTapQualification() {}
}

// MARK: - Shared interaction defaults

extension WorkflowViewModel {
    var interactionOutcome: WorkflowInteractionReceipt? { nil }
    var interactionSavedDraft: String? { nil }
}

// MARK: - Goal projection

extension WorkflowViewModel {
    /// The goal block content for `run`, nil until the run projection for that run has arrived.
    func goalPresentation(for run: WorkflowRunModel) -> WorkflowGoalPresentation? {
        runSidebar.goal.flatMap { $0.runID == run.id ? $0 : nil }
    }

    /// The retained winning receipt when the run's goal block shows its answered-elsewhere card, nil otherwise.
    /// The card and the screen header's copy of the outcome both read this, from the same projection, so the outcome
    /// is shown exactly once.
    func goalAnsweredElsewhere(for model: WorkflowGoalPresentation?) -> WorkflowInteractionReceipt? {
        guard let model, let outcome = interactionOutcome, goalDraft?.runID != model.runID,
              WorkflowGoalPresentation.showsAnsweredElsewhere(
                  outcomeAction: outcome.action, expectedRevision: goalRaceExpectedRevision, runRevision: model.goalRevision)
        else { return nil }
        return outcome
    }
}
