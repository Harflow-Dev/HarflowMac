import MonitorCore

// MARK: - WorkflowVM run control

extension WorkflowVM {
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
        guard !isBusy, let run = selectedRun,
              run.permitsMonitor(command, fallback: command == "cancel" ? run.canCancelFromMonitor : run.allowsMonitorControl) else { return }
        guard !allowOptionalReviewSkip || (command == "resume" && run.canSkipOptionalReview) else { return }
        if ["resume", "recover"].contains(command) {
            guard run.canSubmitContinuation(command, instructions: instructions) else { return }
        }
        // Capture the displayed checkpoint and answer before scheduling asynchronous work.
        let runID = run.id
        var options = ["--monitor"]
        if command == "resume" || command == "recover" {
            let reasonFlag = command == "recover" ? "--reason" : "--instructions"
            options.append("\(reasonFlag)=\(instructions)")
            if !run.isSchedulerRecovery { options.append("--additional-attempts=\(additionalAttempts)") }
        }
        if command == "resume", let decisionID = run.raw["input_decision_id"]?.stringValue {
            options.append("--decision-id=\(decisionID)")
        }
        if allowOptionalReviewSkip {
            options.append("--allow-optional-review-skip")
        }
        let capturedOptions = options
        perform { [weak self] in
            guard let self else { return }
            do {
                _ = try await useCase.command(command, options: capturedOptions, positionals: [runID])
            } catch {
                await refresh()
                throw error
            }
            await refresh()
        }
    }

}
