import Foundation

// MARK: - WorkflowVM operation lifecycle

extension WorkflowVM {
    func perform(_ work: @escaping @MainActor () async throws -> Void) {
        guard validateBuilderRuntime(), !operationBusy else {
            return
        }
        isBusy = true
        errorText = nil
        let runtime = selectedRun?.isBuilder == true ? builderRuntime : nil
        let runID = selectedRun?.id
        operation = Task { [weak self] in
            guard let self else { return }
            if let runtime {
                guard selectedRun?.id == runID, (try? useCase.activityRuntime()) == runtime, validateBuilderRuntime() else {
                    isBusy = false
                    return
                }
            }
            do { try await work() } catch {
                if runtime == nil || (selectedRun?.id == runID && (try? useCase.activityRuntime()) == runtime) {
                    errorText = Self.message(error)
                }
            }
            isBusy = false
        }
    }

}
