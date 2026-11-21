import Foundation

// MARK: - ParallelComposerLocks

/// Composer locks a workflow VM sets on its own `ParallelVM`s; the default is unlocked.
struct ParallelComposerLocks: Equatable {
    /// The run whose lanes these are was cancelled. Read by `.lane` chrome columns.
    var runCancelled = false
    var phase: ParallelMessageLock?
    /// The runtime has no queued messaging. Workflow-owned lanes and inspectors share its answer.
    var messagingUnsupported = false
}

// MARK: - ParallelVM workflow composer locks

extension ParallelVM {
    static let fallbackFooter = "Enforcement differs between these agents; see each task's details."

    var isRunMessageLocked: Bool { composerLocks.phase != nil || composerLocks.runCancelled }
    var isMessagingUnsupported: Bool { composerLocks.messagingUnsupported }

    /// Chrome and the lock its composer reads travel together, so a column never shows one without the other.
    func applyChrome(to column: inout ParallelColumnModel) {
        column.hidesInspectorComposer = isWorkflowInspector && steeringComposerOwned
        column.chrome = isWorkflowInspector ? .inspector : .lane
        column.messageAdmission = workflowMessageAdmission
        column.messageLock = composerLocks.phase
            ?? (composerLocks.runCancelled && !isWorkflowInspector ? .runCancelled : nil)
            ?? (composerLocks.messagingUnsupported && (workflowMessageScope != nil || isWorkflowInspector) ? .messagingUnsupported : nil)
        column.inspectorApproval = column.chrome == .inspector && inspectorApprovalGate.mounts ? inspectorApprovalGate : nil
    }

    /// Locks every lane composer of a cancelled run. Cleared on `didDisappear`, so the workflow VM reapplies it on
    /// appearance. Republishes the columns only when the value changes.
    func setWorkflowRunMessageLock(_ locked: Bool) {
        guard composerLocks.runCancelled != locked else { return }
        composerLocks.runCancelled = locked
        if didSubscribe { publishColumns() }
    }

    /// Applies the owner's current policy without changing the cached route's role.
    func setWorkflowMessageState(phase: ParallelMessageLock?, unsupported: Bool, admission: WorkflowMessageAdmission?) {
        guard composerLocks.phase != phase || composerLocks.messagingUnsupported != unsupported || workflowMessageAdmission != admission else { return }
        composerLocks.runCancelled = false
        composerLocks.phase = phase
        composerLocks.messagingUnsupported = unsupported
        workflowMessageAdmission = admission
        if didSubscribe { publishColumns() }
    }

    /// Invalidates callbacks on detach; route identity remains with its cached inspector.
    func detachWorkflowMessageState() {
        composerLocks.phase = nil
        composerLocks.runCancelled = false
        if workflowMessageScope != nil { composerLocks.messagingUnsupported = false }
        workflowMessageAdmission = nil
    }

    /// Hides and independently refuses the legacy root inspector composer while steering owns it.
    func setSteeringComposerOwned(_ owned: Bool) {
        guard steeringComposerOwned != owned else { return }
        steeringComposerOwned = owned
        if didSubscribe { publishColumns() }
    }

    /// Locks the node pane's inspector composer on a runtime without queued messaging. Lane columns never read it.
    func setMessagingUnsupported(_ unsupported: Bool) {
        guard composerLocks.messagingUnsupported != unsupported else { return }
        composerLocks.messagingUnsupported = unsupported
        if didSubscribe { publishColumns() }
    }
}

// MARK: - Inspector approval

extension ParallelVM {
    /// Sets the approval panel the node pane draws between the feed and the composer. Republishes only on change.
    func setInspectorApproval(_ gate: WorkflowSelectedApprovalGate) {
        guard inspectorApprovalGate != gate else { return }
        inspectorApprovalGate = gate
        if didSubscribe { publishColumns() }
    }
}

// MARK: - Workflow inspector residency

extension ParallelVM {
    /// Independent workflow inspector ownership with the same activity dependencies.
    func makeWorkflowActivity() -> ParallelVM {
        let activity = ParallelVM(groupName: groupName, useCase: useCase, routing: routing, buildColumns: buildColumns)
        activity.isWorkflowInspector = true
        return activity
    }
}

// MARK: - Workflow message column

extension ParallelVM {
    func messageColumn(presentation: ParallelColumnPresentation, metadata: ParallelColumnPresentation,
                       conversationID: String) -> ParallelColumnModel {
        var column = ParallelColumnModelBuilder.build(presentation: presentation, metadata: metadata,
            onTapTakeover: isWorkflowInspector ? { [weak self] in self?.didTapTakeover(taskID: metadata.task.taskID) } : nil,
            onTapOpenTask: { [weak self] in self?.routing.selectTask(metadata.task.taskID) }, onSelectTask: { [weak self] in self?.routing.selectTask($0) })
        let admission = workflowMessageAdmission
        column.onSubmitMessage = { [weak self] text, now in
            guard let self, admitsWorkflowMessage(admission, taskID: metadata.task.taskID) else { return false }
            return submitMessage(text, conversationID: conversationID, now: now)
        }
        column.onCancelMessage = { [weak self] messageID in self?.cancelMessage(messageID, conversationID: conversationID) }
        return column
    }
}
