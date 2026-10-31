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
        if ["resume", "recover"].contains(command),
           !continuation.isQualified || continuation != WorkflowContinuationDraftContext(run: run) || continuation.command != command {
            errorText = WorkflowContinuationDraftContext.changedMessage
            return
        }
        guard run.permitsMonitor(command, fallback: command == "cancel" ? run.canCancelFromMonitor : run.allowsMonitorControl) else { return }
        guard !allowOptionalReviewSkip || (command == "resume" && run.canSkipOptionalReview) else { return }
        if ["resume", "recover"].contains(command) {
            guard run.canSubmitContinuation(command, instructions: instructions) else { return }
        }
        // Draft identity survives polling; capture the matching request before async work.
        let runID = ["resume", "recover"].contains(command) ? continuation.runID ?? run.id : run.id
        let capturedOptions = controlOptions(command, context: continuation, allowOptionalReviewSkip: allowOptionalReviewSkip)
        perform { [weak self] in
            guard let self else { return }
            do {
                _ = try await useCase.command(command, options: capturedOptions, positionals: [runID])
            } catch {
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
