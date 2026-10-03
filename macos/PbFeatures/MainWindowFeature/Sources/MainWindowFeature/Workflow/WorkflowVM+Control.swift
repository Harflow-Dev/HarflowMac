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
        guard let run = selectedRun, run.allowsMonitorControl else { return }
        if ["resume", "recover"].contains(command) {
            guard !run.isSettling,
                  !(run.requiresAnswer && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                  command != "recover" || run.canRecover else { return }
        }
        perform { [weak self] in
            guard let self else {
                return
            }
            var options: [String] = run.raw["interaction_owner"]?.stringValue == "monitor" ? ["--monitor"] : []
            if command == "resume" || command == "recover" {
                let reasonFlag = command == "recover" ? "--reason" : "--instructions"
                options += ["\(reasonFlag)=\(instructions)", "--additional-attempts=\(additionalAttempts)"]
            }
            if command == "resume", let decisionID = run.raw["input_decision_id"]?.stringValue {
                options.append("--decision-id=\(decisionID)")
            }
            _ = try await useCase.command(command, options: options, positionals: [run.id])
            await refresh()
        }
    }

}
