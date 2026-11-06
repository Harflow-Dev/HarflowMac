import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowRunPolling

/// Reassembles changed authoritative views without repeatedly transferring old results.
@MainActor
final class WorkflowRunPolling {
    nonisolated static let staleDetailMessage = "Workflow details changed while loading. Refreshing the latest revision."
    private var snapshots: [String: [String: JSONValue]] = [:]
    private var recentRuns: [String] = []
    // Native provenance, never a flag accepted from a wire object. Only lossless public
    // snapshot/detail reassembly supplies complete attempt inventory.
    private struct CompleteActivations {
        let runtime: QualificationRuntimeToken
        let values: [String: JSONValue]
    }

    private var completeActivations: [String: CompleteActivations] = [:]
    private var selectedRuntime: QualificationRuntimeToken?

    private func alignRuntime(_ runtime: QualificationRuntimeToken?) {
        guard selectedRuntime != runtime else { return }
        selectedRuntime = runtime
        loadID = UUID()
        snapshots = [:]; recentRuns = []; completeActivations = [:]
        runID = nil; digests = [:]; values = [:]; executions = [:]; executionDigests = [:]
    }

    func activityIntent(runID: String, activation: [String: JSONValue], runtime: QualificationRuntimeToken?) -> WorkflowActivityReadIntent {
        alignRuntime(runtime)
        guard let runtime, let proof = completeActivations[runID], proof.runtime == runtime,
              let id = activation["id"]?.stringValue,
              proof.values[id]?.objectValue == activation,
              let status = activation["status"]?.stringValue,
              Self.terminalStatuses.contains(status),
              ["tasks_truncated", "attempts_truncated"].allSatisfy({ activation[$0] == nil || activation[$0] == .bool(false) }),
              let tasks = activation["tasks"]?.arrayValue,
              tasks.allSatisfy({ task in
                  guard let raw = task.objectValue, let state = raw["status"]?.stringValue,
                        raw["task_id"]?.stringValue?.isEmpty == false else { return false }
                  return Self.terminalStatuses.contains(state)
              }) else { return .allowUnsettled }
        if snapshots[runID]?["execution_contract"]?.stringValue == "delegation", status != "cancelled",
           !["succeeded", "failed", "blocked"].contains(activation["node_result"]?["status"]?.stringValue ?? "") {
            return .allowUnsettled
        }
        return .settledOnly
    }

    private static let terminalStatuses: Set<String> = ["completed", "failed", "cancelled", "blocked", "timed_out", "succeeded"]

    private func captureCompleteActivations(_ raw: [String: JSONValue], id: String, runtime: QualificationRuntimeToken?) {
        guard let runtime, runtime == selectedRuntime, raw["activations_truncated"] == nil || raw["activations_truncated"] == .bool(false),
              let rows = raw["activations"]?.arrayValue else { completeActivations[id] = nil; return }
        var result: [String: JSONValue] = [:]
        for row in rows {
            guard let activation = row.objectValue, let key = activation["id"]?.stringValue,
                  !key.isEmpty, result[key] == nil else { completeActivations[id] = nil; return }
            result[key] = row
        }
        completeActivations[id] = CompleteActivations(runtime: runtime, values: result)
    }

    func cached(id: String) -> [String: JSONValue]? {
        guard WorkflowRunIdentity.isValid(id), let raw = snapshots[id],
              raw["workflow_run_id"]?.stringValue == id, raw["status"]?.stringValue?.isEmpty == false else { return nil }
        return raw
    }

    private func remember(_ raw: [String: JSONValue], id: String) {
        guard WorkflowRunIdentity.isValid(id), raw["workflow_run_id"]?.stringValue == id,
              raw["status"]?.stringValue?.isEmpty == false else { return }
        snapshots[id] = raw
        recentRuns.removeAll { $0 == id }
        recentRuns.append(id)
        if recentRuns.count > 8 {
            let removed = recentRuns.removeFirst()
            snapshots.removeValue(forKey: removed)
            completeActivations.removeValue(forKey: removed)
        }
    }

    private var runID: String?
    private var loadID = UUID()
    private var digests: [String: String] = [:]
    private var values: [String: JSONValue] = [:]
    private var executions: [String: JSONValue] = [:]
    private var executionDigests: [String: String] = [:]

    func load(id: String, useCase: any WorkflowUseCase) async throws -> [String: JSONValue] {
        let metricStart = MonitorMetrics.begin()
        defer { MonitorMetrics.end(metricStart, stage: .workflowLoad) }
        let runtime = try? useCase.activityRuntime()
        alignRuntime(runtime)
        let generation = UUID()
        loadID = generation
        let (response, isCached) = try await status(id: id, useCase: useCase)
        guard (try? useCase.activityRuntime()) == runtime else { alignRuntime(try? useCase.activityRuntime()); throw CancellationError() }
        guard loadID == generation else { throw CancellationError() }
        if !CatalogState(raw: response).isReady { return response }
        if isCached { return response }
        if response["monitor_snapshot"]?.boolValue == true {
            let raw = try await WorkflowMonitorSnapshot.read(first: response, id: id, useCase: useCase, runtime: runtime)
            guard loadID == generation else { throw CancellationError() }
            await seedSnapshot(raw, id: id, generation: generation, useCase: useCase)
            guard loadID == generation else { throw CancellationError() }
            guard (try? useCase.activityRuntime()) == runtime else { alignRuntime(try? useCase.activityRuntime()); throw CancellationError() }
            captureCompleteActivations(raw, id: id, runtime: runtime)
            remember(raw, id: id)
            return raw
        }
        return try await loadLegacy(response: response, id: id, generation: generation, useCase: useCase)
    }

    private func status(id: String, useCase: any WorkflowUseCase) async throws -> ([String: JSONValue], Bool) {
        let previous = snapshots[id]
        let hasDigests = previous?["monitor_digests"]?.objectValue != nil
        let options = hasDigests ? ["--monitor-view"] : ["--monitor-view", "--snapshot"]
        let response = try await useCase.command("status", options: options, positionals: [id], runtime: selectedRuntime)
        let stateKeys = [
            "status", "updated_at", "settling", "draft_revision", "input_decision_id", "revision",
            "interaction_owner", "interaction_state", "interaction_history", "can_cancel_from_monitor", "monitor_cancel_reason", "monitor_controls", "messages",
            "can_revise_goal", "goal_revision_reason", "goal_revision", "goal_replanning_required", "goal_replanning_revision"
        ]
        if hasDigests, let previous, stateKeys.allSatisfy({ response[$0] == previous[$0] }),
           let advertised = response["monitor_digests"], advertised == previous["monitor_digests"] {
            return (previous, true)
        }
        return (response, false)
    }

    private func seedSnapshot(_ raw: [String: JSONValue], id: String, generation: UUID, useCase: any WorkflowUseCase) async {
        guard let advertised = raw["monitor_digests"]?.objectValue else { return }
        runID = id
        digests = [:]; values = [:]; executions = [:]; executionDigests = [:]
        for (field, value) in advertised where field != "execution_index" {
            if let digest = value.stringValue { digests[field] = digest; values[field] = raw[field] ?? .null }
        }
        guard let digest = advertised["execution_index"]?.stringValue else { return }
        // Snapshot activations are complete, but their individual digests live in the bounded index.
        // A concurrent advance may invalidate that view; keep the valid frozen bootstrap regardless.
        guard let index = try? await read(id: id, view: "execution_index", expectedDigest: digest, useCase: useCase),
              loadID == generation else { return }
        values["execution_index"] = index; digests["execution_index"] = digest
        let byID = Dictionary(WorkflowJSON.objects(raw["activations"]).compactMap { execution -> (String, JSONValue)? in
            guard let id = execution["id"]?.stringValue else { return nil }
            return (id, .object(execution))
        }, uniquingKeysWith: { first, _ in first })
        for row in WorkflowJSON.objects(index) {
            if let id = row["id"]?.stringValue, let digest = row["digest"]?.stringValue, let value = byID[id] {
                executions[id] = value; executionDigests[id] = digest
            }
        }
    }

    private func loadLegacy(response: [String: JSONValue], id: String, generation: UUID,
                            useCase: any WorkflowUseCase) async throws -> [String: JSONValue] {
        let runtime = selectedRuntime
        let metadata = response["run"]?.objectValue ?? response
        // Preview fixtures and old CLI responses retain their existing complete shape.
        guard let advertised = metadata["monitor_digests"]?.objectValue else {
            remember(metadata, id: id)
            return metadata
        }
        if runID != id {
            runID = id
            digests = [:]
            values = [:]
            executions = [:]
            executionDigests = [:]
        }
        for field in advertised.keys.sorted() {
            guard let digest = advertised[field]?.stringValue, digests[field] != digest else { continue }
            let value = try await read(id: id, view: field, expectedDigest: digest, useCase: useCase)
            guard loadID == generation else { throw CancellationError() }
            values[field] = value
            digests[field] = digest
        }
        let ordered = try await loadExecutions(id: id, generation: generation, useCase: useCase)
        guard loadID == generation else { throw CancellationError() }
        let reconciliationStart = MonitorMetrics.begin()
        defer { MonitorMetrics.end(reconciliationStart, stage: .workflowReconciliation) }
        var result = metadata
        for (field, value) in values where field != "execution_index" {
            if value == .null { result.removeValue(forKey: field) } else { result[field] = value }
        }
        result["activations"] = .array(ordered)
        guard (try? useCase.activityRuntime()) == runtime else { alignRuntime(try? useCase.activityRuntime()); throw CancellationError() }
        captureCompleteActivations(result, id: id, runtime: runtime)
        remember(result, id: id)
        return result
    }

    private func loadExecutions(id: String, generation: UUID, useCase: any WorkflowUseCase) async throws -> [JSONValue] {
        guard let value = values["execution_index"] else { return [] }
        guard let rows = value.arrayValue,
              rows.allSatisfy({ $0.objectValue != nil }) else { throw PollingError.invalidDetail }
        let index = rows.compactMap(\.objectValue)
        var ordered: [JSONValue] = []
        for row in index {
            guard let executionID = row["id"]?.stringValue, let digest = row["digest"]?.stringValue else {
                throw PollingError.invalidDetail
            }
            if executionDigests[executionID] != digest {
                let value = try await read(id: id, view: "execution:\(executionID)", expectedDigest: digest, useCase: useCase)
                guard loadID == generation else { throw CancellationError() }
                executions[executionID] = value
                executionDigests[executionID] = digest
            }
            guard let execution = executions[executionID] else { throw PollingError.invalidDetail }
            ordered.append(execution)
        }
        return ordered
    }

    private func read(id: String, view: String, expectedDigest: String, useCase: any WorkflowUseCase) async throws -> JSONValue {
        // A changing view invalidates its cursor. Restart once rather than joining
        // chunks from two revisions; another change is retried by the next poll.
        let runtime = selectedRuntime
        for attempt in 0 ... 1 {
            guard selectedRuntime == runtime else { throw CancellationError() }
            do {
                return try await readPages(id: id, view: view, expectedDigest: expectedDigest, useCase: useCase, runtime: runtime)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt == 1 { throw error }
            }
        }
        throw PollingError.invalidDetail
    }

    private func readPages(id: String, view: String, expectedDigest: String, useCase: any WorkflowUseCase,
                           runtime: QualificationRuntimeToken?) async throws -> JSONValue {
        var cursor: String?
        var digest: String?
        var text = ""
        repeat {
            try Task.checkCancellation()
            guard selectedRuntime == runtime else { throw CancellationError() }
            var options = ["--monitor-view", "--view=\(view)"]
            if let cursor { options.append("--cursor=\(cursor)") }
            let page = try await useCase.command("detail", options: options, positionals: [id], runtime: runtime)
            guard page["workflow_run_id"]?.stringValue == id, page["view"]?.stringValue == view,
                  let chunk = page["chunk"]?.stringValue, let pageDigest = page["content_sha256"]?.stringValue,
                  pageDigest == expectedDigest,
                  page["offset"]?.intValue == text.utf8.count,
                  digest == nil || digest == pageDigest else { throw PollingError.invalidDetail }
            digest = pageDigest
            text += chunk
            cursor = page["next_cursor"]?.stringValue
            if cursor == nil, page["total_characters"]?.intValue != text.utf8.count { throw PollingError.invalidDetail }
        } while cursor != nil
        guard let value = JSONValue.parse(Data(text.utf8)) else { throw PollingError.invalidDetail }
        return value
    }

    private enum PollingError: LocalizedError {
        case invalidDetail
        var errorDescription: String? { WorkflowRunPolling.staleDetailMessage }
    }
}
