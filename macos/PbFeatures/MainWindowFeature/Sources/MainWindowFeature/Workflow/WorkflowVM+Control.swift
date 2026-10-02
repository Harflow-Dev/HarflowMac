import MonitorCore

// MARK: - WorkflowVM run control

extension WorkflowVM {
    func continueWithOneMoreRetry() {
        guard selectedRun?.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false else { return }
        additionalAttempts = 1
        control("resume")
    }

    func control(_ command: String) {
        guard let runID = selectedRun?.id else {
            return
        }
        perform { [weak self] in
            guard let self else {
                return
            }
            let options = command == "resume" ? ["--instructions=\(instructions)", "--additional-attempts=\(additionalAttempts)"] : []
            _ = try await useCase.command(command, options: options, positionals: [runID])
            await refresh()
        }
    }

}
