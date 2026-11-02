import MonitorCore

// MARK: - WorkflowContinuationDraftContext

struct WorkflowContinuationDraftContext: Equatable {
    static let changedMessage = "This checkpoint changed or its identity is unavailable. "
        + "Review the current request, then clear instructions and reset extra attempts before entering a new answer. "
        + "Your draft is preserved."

    let runID: String?
    let command: String?
    let isSchedulerRecovery: Bool
    let decisionID: String?
    let attentionCheckpointID: String?

    init(run: WorkflowRunModel?) {
        self.runID = run?.id
        self.command = run?.recoveryCommand
        self.isSchedulerRecovery = run?.isSchedulerRecovery ?? false
        self.decisionID = run?.recoveryCommand == "resume" ? run?.continuationDecisionID : nil
        self.attentionCheckpointID = decisionID == nil ? run?.attentionCheckpointID : nil
    }

    var interactionID: String? { decisionID ?? attentionCheckpointID }

    var isQualified: Bool {
        runID?.isEmpty == false && (decisionID != nil || attentionCheckpointID != nil)
    }
}

// MARK: - WorkflowVM run control

extension WorkflowVM {
    func updateContinuationDraftContext() {
        if instructions.isEmpty, additionalAttempts == 0 {
            continuationDraftContext = nil
        } else if continuationDraftContext == nil {
            continuationDraftContext = WorkflowContinuationDraftContext(run: selectedRun)
        }
    }

    func continueWithOneMoreRetry() {
        guard let run = selectedRun, run.permitsMonitor("additional_attempts", fallback: run.allowsMonitorControl), !run.isSchedulerRecovery,
              run.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false,
              run.canSubmitContinuation(run.recoveryCommand, instructions: instructions) else { return }
        let command = run.recoveryCommand
        guard command != "recover" || run.canRecover else { return }
        additionalAttempts = 1
        control(command)
    }

    func control(_ command: String) {
        control(command, allowOptionalReviewSkip: false)
    }

    func control(_ command: String, allowOptionalReviewSkip: Bool) {
        guard !isBusy, let run = selectedRun else { return }
        let continuation = continuationDraftContext ?? WorkflowContinuationDraftContext(run: run)
        guard permitsControl(command, run: run, continuation: continuation, allowOptionalReviewSkip: allowOptionalReviewSkip) else { return }
        // Draft identity survives polling; capture the matching request before async work.
        let runID = ["resume", "recover"].contains(command) ? continuation.runID ?? run.id : run.id
        let submittedDraft = instructions
        let capturedOptions = controlOptions(command, context: continuation, allowOptionalReviewSkip: allowOptionalReviewSkip)
        perform { [weak self] in
            guard let self else { return }
            do {
                let result = try await useCase.command(command, options: capturedOptions, positionals: [runID])
                if let receipt = WorkflowMonitorStatus(result).interactionHistory.last(where: { $0.interactionID == continuation.interactionID }) {
                    retainInteractionOutcome(receipt, draft: nil, rootID: runID)
                }
            } catch {
                if let winner = (error as? ToolError)?.workflowInteractionWinner {
                    retainInteractionOutcome(winner, draft: submittedDraft, rootID: runID)
                    await refresh()
                    return
                }
                await refresh()
                if (error as? ToolError)?.refusalCode == "attention_checkpoint_stale" {
                    throw ToolError.refused(
                        code: "attention_checkpoint_stale",
                        message: WorkflowContinuationDraftContext.changedMessage
                    )
                }
                throw error
            }
            await refresh()
        }
    }

    private func permitsControl(_ command: String, run: WorkflowRunModel, continuation: WorkflowContinuationDraftContext,
                                allowOptionalReviewSkip: Bool) -> Bool {
        if ["resume", "recover"].contains(command),
           interactionOutcome != nil, interactionOutcome?.interactionID == continuation.interactionID { return false }
        if ["resume", "recover"].contains(command),
           !continuation.isQualified || continuation != WorkflowContinuationDraftContext(run: run) || continuation.command != command {
            errorText = WorkflowContinuationDraftContext.changedMessage
            return false
        }
        guard run.permitsMonitor(command, fallback: command == "cancel" ? run.canCancelFromMonitor : run.allowsMonitorControl) else { return false }
        guard !allowOptionalReviewSkip || (command == "resume" && run.canSkipOptionalReview) else { return false }
        if ["resume", "recover"].contains(command) {
            guard run.canSubmitContinuation(command, instructions: instructions) else { return false }
        }
        return true
    }

    func retainInteractionOutcome(_ receipt: WorkflowInteractionReceipt, draft: String?, rootID: String? = nil) {
        let root = rootID ?? selectedRun?.id
        if interactionOutcomeRootID != root { interactionOutcomeRootID = root }
        if retainedInteractionOutcome != receipt { retainedInteractionOutcome = receipt }
        if interactionSavedDraft != draft { interactionSavedDraft = draft }
    }

    private func controlOptions(_ command: String, context: WorkflowContinuationDraftContext, allowOptionalReviewSkip: Bool) -> [String] {
        var options = ["--monitor"]
        if ["resume", "recover"].contains(command) {
            let reasonFlag = command == "recover" ? "--reason" : "--instructions"
            options.append("\(reasonFlag)=\(instructions)")
            if !context.isSchedulerRecovery { options.append("--additional-attempts=\(additionalAttempts)") }
            if command == "resume", let decisionID = context.decisionID {
                options.append("--decision-id=\(decisionID)")
            } else if let checkpoint = context.attentionCheckpointID {
                options.append("--attention-checkpoint-id=\(checkpoint)")
            }
        }
        if allowOptionalReviewSkip { options.append("--allow-optional-review-skip") }
        return options
    }

}
