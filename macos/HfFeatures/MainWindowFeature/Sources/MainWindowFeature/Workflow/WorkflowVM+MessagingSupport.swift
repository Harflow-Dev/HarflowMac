import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowVM messaging truth

extension WorkflowVM {
    var messagingUnsupported: Bool {
        guard messagingSupported == false else { return false }
        guard let support = messagingSupport else { return true }
        guard let context = messagingSupportContext else { return false }
        return support.isMessagingContextCurrent(context) && (try? support.messagingInvocationContext()) == context
    }

    /// Publishes one current policy to the lane owner and each retained inspector route.
    func applyRunMessageLock() {
        parallel.workflowMessageScope = selectedRun.map {
            WorkflowMessageScope(runID: $0.id, nodeID: nil, activationID: nil, role: $0.isBuilder ? .builderLanes : .lanes)
        }
        parallel.messagingFailureHandler = { [weak self] in self?.makeMessagingFailureHandler() ?? { _ in } }
        let activities = [parallel] + Array(activityCache.values)
        for activity in activities {
            activity.workflowMessageAdmissionHandler = { [weak self] admission, taskID in
                self?.admitsWorkflowMessage(admission, taskID: taskID) == true
            }
            let scope = activity.workflowMessageScope
            let matching = scope?.runID == selectedRun?.id
            let admission = matching ? scope.map(makeWorkflowMessageAdmission) : nil
            activity.setWorkflowMessageState(
                phase: matching ? scope?.phaseLock(selectedRun?.status ?? "") : nil,
                unsupported: matching && messagingUnsupported && scope?.role != .builderLanes, admission: admission)
        }
    }

    func makeWorkflowMessageAdmission(_ scope: WorkflowMessageScope) -> WorkflowMessageAdmission {
        WorkflowMessageAdmission(scope: scope, appearanceID: messagingAppearanceID, routeID: messagingRouteID,
                                 context: try? messagingSupport?.messagingInvocationContext())
    }

    /// Admission rechecks the owner and exact source route; a child target never supplies its parent's phase.
    func admitsWorkflowMessage(_ admission: WorkflowMessageAdmission, taskID: String? = nil) -> Bool {
        guard didSubscribe, messagingAppearanceID == admission.appearanceID, messagingRouteID == admission.routeID,
              let run = selectedRun, run.id == admission.scope.runID,
              admission.scope.phaseLock(run.status) == nil,
              !messagingUnsupported || admission.scope.role == .builderLanes else { return false }
        if let support = messagingSupport {
            guard let context = admission.context, support.isMessagingContextCurrent(context),
                  (try? support.messagingInvocationContext()) == context else { return false }
        }
        let scope = admission.scope
        if scope.nodeID != nil {
            guard runGraphVisible, sidebarTask == nil, selectedNodeID == scope.nodeID,
                  runSidebar.node?["id"]?.stringValue == scope.nodeID,
                  runSidebar.activationID == scope.activationID,
                  selectedActivationID == nil || selectedActivationID == scope.activationID else { return false }
        } else if runGraphVisible { return false }
        if let taskID {
            let activations = run.activations.filter { activation in
                scope.activationID == nil || activation["id"]?.stringValue == scope.activationID
            }
            guard activations.contains(where: { activation in
                WorkflowJSON.objects(activation["tasks"]).contains { $0["task_id"]?.stringValue == taskID }
            }) else { return false }
        }
        return true
    }

    /// Probes the runtime once per invocation context. Unknown (`nil`) leaves sending enabled.
    func prepareMessagingSupport() {
        guard didSubscribe, let support = messagingSupport else { return }
        guard let context = try? support.messagingInvocationContext() else {
            if messagingSupportContext != nil { messagingRouteID = UUID() }
            messagingSupportRead?.cancel()
            messagingSupportRead = nil
            messagingSupportContext = nil
            setMessagingSupported(nil)
            return
        }
        guard messagingSupportContext != context else { return }
        messagingRouteID = UUID()
        messagingSupportRead?.cancel()
        messagingSupportContext = context
        setMessagingSupported(nil)
        applyRunMessageLock()
        messagingSupportRead = Task { [weak self] in
            let supported = await support.messagingSupport(context: context)
            guard let self, didSubscribe, !Task.isCancelled, messagingSupportContext == context,
                  support.isMessagingContextCurrent(context) else { return }
            setMessagingSupported(supported)
        }
    }

    func invalidateMessagingSupport() {
        messagingAppearanceID = UUID()
        messagingSupportRead?.cancel()
        messagingSupportRead = nil
        messagingSupportContext = nil
        setMessagingSupported(nil)
    }

    /// Capture before dispatch: an old send cannot replace a new runtime's answer or a later appearance's state.
    func makeMessagingFailureHandler() -> @MainActor (any Error) -> Void {
        let context = try? messagingSupport?.messagingInvocationContext()
        let appearance = messagingAppearanceID
        return { [weak self] error in
            guard let self, didSubscribe, messagingAppearanceID == appearance, let context,
                  messagingSupport?.isMessagingContextCurrent(context) == true,
                  (try? messagingSupport?.messagingInvocationContext()) == context else { return }
            noteMessagingSendFailure(error, context: context)
        }
    }

    /// A current send refused for the missing capability proves the answer faster than the next probe.
    private func noteMessagingSendFailure(_ error: any Error, context: MessagingInvocationContext) {
        guard case .unsupportedCommand(_, _, let detail) = error as? ToolError,
              detail == "Missing capability messaging.v1" else { return }
        messagingSupportRead?.cancel()
        messagingSupportRead = nil
        messagingSupportContext = context
        setMessagingSupported(false)
    }

    private func setMessagingSupported(_ value: Bool?) {
        guard messagingSupported != value else { return }
        messagingSupported = value
        pushMessagingSupport()
    }

    /// Cached roles remain stable while their owner's current answer changes.
    private func pushMessagingSupport() {
        applyRunMessageLock()
    }
}
