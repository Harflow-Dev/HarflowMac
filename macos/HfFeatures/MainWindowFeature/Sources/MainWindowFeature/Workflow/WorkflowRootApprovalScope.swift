import MonitorCore

// MARK: - WorkflowRootApprovalScope

/// Direct issued worker membership from the selected public run observation.
struct WorkflowRootApprovalScope: Equatable, Sendable {
    struct Subject: Equatable, Sendable {
        let taskID: String
        let activationID: String
        let nodeID: String
        let issuer: String
    }

    let rootID: String
    let subjects: [Subject]

    init(run: WorkflowRunModel) {
        self.rootID = run.id
        guard WorkflowSteeringPresentation.isRegularRoot(run.raw) else { self.subjects = []; return }
        let nodes = WorkflowJSON.objects(run.definition["nodes"])
        self.subjects = WorkflowJSON.objects(run.raw["activations"]).flatMap { activation -> [Subject] in
            guard activation["role"]?.stringValue == "node",
                  let id = activation["id"]?.stringValue, !id.isEmpty,
                  let nodeID = activation["node_id"]?.stringValue, !nodeID.isEmpty else { return [] }
            let title = nodes.first { $0["id"]?.stringValue == nodeID }?["title"]?.stringValue
                ?? activation["title"]?.stringValue ?? nodeID
            return WorkflowJSON.objects(activation["tasks"]).compactMap { task in
                guard let taskID = task["task_id"]?.stringValue, !taskID.isEmpty else { return nil }
                return Subject(taskID: taskID, activationID: id, nodeID: nodeID, issuer: title)
            }
        }
    }

    /// A positive paused hold can coexist with running workers; terminal snapshots remain one-shot.
    static func shouldPoll(run: WorkflowRunModel) -> Bool {
        WorkflowSelectedApprovalGate.pollingStatuses.contains(run.status)
            || (run.status == "paused" && WorkflowSteeringPresentation.hasPositiveHold(run.raw))
    }

    func contains(_ request: CallerApprovalRequest) -> Bool { subject(for: request) != nil }

    func issuer(for request: CallerApprovalRequest) -> String? { subject(for: request)?.issuer }

    private func subject(for request: CallerApprovalRequest) -> Subject? {
        guard request.text("root_workflow_run_id") == rootID, request.text("workflow_run_id") == rootID else { return nil }
        let matches = subjects.filter { $0.taskID == request.taskID }
        guard matches.count == 1, let subject = matches.first,
              request.text("workflow_execution_id") == subject.activationID,
              request.text("workflow_node_id") == subject.nodeID else { return nil }
        return subject
    }
}

extension WorkflowViewModel {
    /// The rendered regular-root selection owns the run approval query, using the same admission as the Run pane.
    var rootOwnsCallerApprovals: Bool {
        steeringOwnsComposer && selectedRun.map { WorkflowSelectedApprovalGate.make(run: $0.raw).mounts } == true
    }
}
