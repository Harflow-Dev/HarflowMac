import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowMessageScope

/// The route a workflow composer belongs to, independent of its transient phase or capability.
struct WorkflowMessageScope: Equatable, Sendable {
    enum Role: Equatable, Sendable { case lanes, node, orchestrator, builderLanes, builderNode }

    let runID: String
    let nodeID: String?
    let activationID: String?
    let role: Role

    func phaseLock(_ phase: String) -> ParallelMessageLock? {
        switch role {
        case .lanes, .orchestrator:
            switch phase {
            case "completed": .runCompleted
            case "cancelling": .runCancelling
            case "cancelled": .runCancelled
            default: nil
            }
        case .node, .builderLanes: phase == "cancelled" ? .runCancelled : nil
        case .builderNode: nil
        }
    }

    static func activity(run: WorkflowRunModel?, sidebar: WorkflowRunSidebarPresentation) -> Self? {
        guard let run, let nodeID = sidebar.node?["id"]?.stringValue else { return nil }
        let role: Role = run.isBuilder ? .builderNode
            : sidebar.header.kind == .orchestrator && run.parentRunID != nil ? .orchestrator : .node
        return Self(runID: run.id, nodeID: nodeID, activationID: sidebar.activationID, role: role)
    }
}

// MARK: - WorkflowMessageAdmission

/// Identity captured by a rendered callback; phase and capability are checked again at invocation.
struct WorkflowMessageAdmission: Equatable, Sendable {
    let scope: WorkflowMessageScope
    let appearanceID: UUID
    let routeID: UUID
    let context: MessagingInvocationContext?
}
