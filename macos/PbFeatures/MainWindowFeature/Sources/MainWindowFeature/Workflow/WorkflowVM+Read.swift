import Foundation
import MonitorCore
import PbCommon

// MARK: - WorkflowReadContext

struct WorkflowReadContext {
    let runID: String?
    let loadingID: UUID
    let generation: UUID?
    var source: String { runID.map { "workflow-run:" + $0 } ?? "workflow-definitions" }

    @MainActor func isCurrent(_ vm: WorkflowVM) -> Bool {
        !Task.isCancelled && vm.selectedRun?.id == runID && vm.initialLoadingID == loadingID
            && (generation == nil || generation == vm.generationID)
    }
}

// MARK: - WorkflowVM read lifecycle

extension WorkflowVM {
    func reportReadFailure(_ message: String, source: String, retry: AlertAction) {
        readFailures[source] = message
        readRetries[source] = retry
        currentReadFailureSource = source
        refreshErrorText = message
        errorText = message
        publishViewEvent(.incident(source: source, message: message, retry: retry))
    }

    func resolveReadFailure(source: String) {
        let previous = readFailures.removeValue(forKey: source)
        readRetries.removeValue(forKey: source)
        if currentReadFailureSource == source {
            currentReadFailureSource = nil
            if errorText == previous { errorText = nil }
            if refreshErrorText == previous { refreshErrorText = nil }
        } else if currentReadFailureSource == nil, errorText == refreshErrorText || errorText == WorkflowRunPolling.staleDetailMessage {
            errorText = nil
            refreshErrorText = nil
        }
        publishViewEvent(.incidentResolved(source: source))
    }

    func retryReadFailure() {
        guard let source = currentReadFailureSource else { return }
        readRetries[source]?.action()
    }

    func refresh(generation: UUID? = nil) async {
        reconnectBuilderSession()
        let context = WorkflowReadContext(runID: selectedRun?.id, loadingID: initialLoadingID, generation: generation)
        var preparing = false
        defer { finishRunRead(context, preparing: preparing) }
        do {
            let response = try await readWorkflow(context)
            guard context.isCurrent(self) else { return }
            let state = CatalogState(raw: response)
            switch state.status {
            case .preparing: preparing = true
            case .blocked: reportReadFailure(state.reason ?? "Workflow catalog is blocked.", source: context.source, retry: readRetry(context))
            case .ready:
                try applyWorkflowRead(response, context: context)
                resolveReadFailure(source: context.source)
            }
        } catch {
            guard context.isCurrent(self) else { return }
            reportReadFailure(Self.message(error), source: context.source, retry: readRetry(context))
        }
    }

    private func readWorkflow(_ context: WorkflowReadContext) async throws -> [String: JSONValue] {
        if let id = context.runID {
            guard WorkflowRunIdentity.isValid(id) else { throw WorkflowReadResponseError.invalidIdentity }
            return try await runPolling.load(id: id, useCase: useCase)
        }
        return try await useCase.command("list", options: [], positionals: [])
    }

    private func readRetry(_ context: WorkflowReadContext) -> AlertAction {
        AlertAction(title: "Refresh workflow") { [weak self] in
            guard let self, selectedRun?.id == context.runID else { return }
            Task { await self.refresh() }
        }
    }

    private func applyWorkflowRead(_ response: [String: JSONValue], context: WorkflowReadContext) throws {
        guard context.runID != nil else {
            workflows = WorkflowJSON.objects(response["workflows"]).map { WorkflowRecord(raw: $0) }
            return
        }
        let raw = response["run"]?.objectValue ?? response
        guard raw["workflow_run_id"]?.stringValue == context.runID,
              let status = raw["status"]?.stringValue, !status.isEmpty else {
            throw WorkflowReadResponseError.invalidRun
        }
        selectedRun = WorkflowRunModel(raw: raw)
        initialLoadFailed = selectedRun?.raw["status"]?.stringValue == nil
        updateActivityMembership()
    }

    private func finishRunRead(_ context: WorkflowReadContext, preparing: Bool) {
        guard !preparing, context.isCurrent(self), context.runID != nil, initialLoadingKind == "run" else { return }
        initialLoadingKind = nil
        initialLoadFailed = selectedRun?.raw["status"]?.stringValue == nil
    }
}

// MARK: - WorkflowReadResponseError

private enum WorkflowReadResponseError: LocalizedError {
    case invalidRun
    case invalidIdentity
    var errorDescription: String? {
        switch self {
        case .invalidRun: "Polybridge returned incomplete details or a different workflow run. Refresh to try again."
        case .invalidIdentity: "This workflow link has an invalid run identifier. Select a workflow from the sidebar."
        }
    }
}
