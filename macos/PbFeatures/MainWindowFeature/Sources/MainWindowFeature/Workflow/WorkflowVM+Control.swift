import MonitorCore

// MARK: - WorkflowVM run control

extension WorkflowVM {
    func continueWithOneMoreRetry() {
        guard let run = selectedRun, run.allowsMonitorControl, !run.isSettling,
              run.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false,
              !(run.requiresAnswer && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return }
        let command = run.isDelegation && run.status == "failed" ? "recover" : "resume"
        guard command != "recover" || run.canRecover else { return }
        additionalAttempts = 1
        control(command)
    }

    func control(_ command: String) {
        control(command, allowOptionalReviewSkip: false)
    }

    func control(_ command: String, allowOptionalReviewSkip: Bool) {
        guard let run = selectedRun, run.allowsMonitorControl else { return }
        guard !allowOptionalReviewSkip || (command == "resume" && run.canSkipOptionalReview) else { return }
        if ["resume", "recover"].contains(command) {
            guard !run.isSettling,
                  !(run.requiresAnswer && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                  command != "recover" || run.canRecover else { return }
        }
        // Capture the displayed checkpoint and answer before scheduling asynchronous work.
        let runID = run.id
        var options: [String] = run.raw["interaction_owner"]?.stringValue == "monitor" ? ["--monitor"] : []
        if command == "resume" || command == "recover" {
            let reasonFlag = command == "recover" ? "--reason" : "--instructions"
            options += ["\(reasonFlag)=\(instructions)", "--additional-attempts=\(additionalAttempts)"]
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
            _ = try await useCase.command(command, options: capturedOptions, positionals: [runID])
            await refresh()
        }
    }

}
