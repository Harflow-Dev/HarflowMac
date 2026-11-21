import Combine
import HfCommon
import HfRepository
import Mockable
import MonitorCore

// MARK: - WorkflowUseCase

@Mockable
@MainActor
protocol WorkflowUseCase: Sendable {
    func steeringObservation(rootID: String) async throws -> WorkflowSteeringObservation
    func steeringHistory(observation: WorkflowSteeringObservation, cursor: String?) async throws -> WorkflowSteeringHistoryPage
    func performSteering(action: WorkflowSteeringAction, text: String?, observation: WorkflowSteeringObservation) async throws -> WorkflowSteeringAttempt
    func steeringAttempts(rootID: String) -> [WorkflowSteeringAttempt]
    func isSteeringCurrent(_ observation: WorkflowSteeringObservation) -> Bool
    func activityRuntime() throws -> QualificationRuntimeToken
    func activity(runID: String, executionID: String, intent: WorkflowActivityReadIntent,
                  runtime: QualificationRuntimeToken) async throws -> WorkflowActivityPage
    func qualificationSession() -> QualificationSession
    func command(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken?) async throws -> [String: JSONValue]
    func boundBuilderCommand(_ command: String, options: [String], positionals: [String], runtime: QualificationRuntimeToken,
                             isCurrent: @escaping @Sendable () -> Bool) async throws -> [String: JSONValue]
    func validate(definition: JSONValue) async throws -> [String: JSONValue]
    func save(name: String, definition: JSONValue, expectedRevision: Int, expectedWorkflowID: String?) async throws -> [String: JSONValue]
    func artifactPage(runID: String, executionID: String, cursor: String?) async -> Result<WorkflowArtifactPage, ToolError>
    func refreshTasks() async
    var backendIDs: [String] { get }
    var agentUsageSnapshot: AgentUsageSnapshot { get }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never>
    func recordAgentUsage(_ identity: AgentUsageIdentity, acknowledgementID: String) async
    var callerApprovalBackends: Set<String> { get }
    var backendCatalog: BackendCatalog { get }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never>
    func modelOptions(backend: String) async -> [ModelOption]
}

// MARK: - WorkflowMessagingSupport

/// The runtime's queued-messaging capability, probed the way the task screen does. Kept apart from `WorkflowUseCase`
/// so a use case that cannot probe leaves the support unknown, which keeps sending enabled.
@Mockable
@MainActor
protocol WorkflowMessagingSupport: Sendable {
    func messagingInvocationContext() throws -> MessagingInvocationContext
    func isMessagingContextCurrent(_ context: MessagingInvocationContext) -> Bool
    /// `nil` when the capability cannot be read for `context` (changed runtime, failed or cancelled check).
    func messagingSupport(context: MessagingInvocationContext) async -> Bool?
}

// MARK: - WorkflowRouting

@Mockable
@MainActor
protocol WorkflowRouting: ParallelRouting {
    func selectTask(_ taskID: String)
    func copyToPasteboard(_ text: String) -> Bool
    func publishTopBar(_ content: GroupTopBarContent, tag: TaskTopBarHolder.Tag)
    func clearTopBar(tag: TaskTopBarHolder.Tag)
    func activateTopBar(tag: TaskTopBarHolder.Tag)
    func deactivateTopBar(tag: TaskTopBarHolder.Tag)
    func retryTopBarActivation(tag: TaskTopBarHolder.Tag)
    func chooseDirectory() async -> String?
    func didSaveWorkflow(name: String)
    func openWorkflowEditor(name: String?)
    func showNeedsYou(itemID: String?)
    func openWorkflowRun(id: String)
}
