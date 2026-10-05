import Foundation
import MonitorCore

// MARK: - WorkflowRunPolling

/// Reassembles changed authoritative views without repeatedly transferring old results.
@MainActor
final class WorkflowRunPolling {
    nonisolated static let staleDetailMessage = "Workflow details changed while loading. Refreshing the latest revision."
    private var snapshots: [String: [String: JSONValue]] = [:]
    private var recentRuns: [String] = []

    func cached(id: String) -> [String: JSONValue]? { snapshots[id] }

    private func remember(_ raw: [String: JSONValue], id: String) {
        snapshots[id] = raw
        recentRuns.removeAll { $0 == id }
        recentRuns.append(id)
        if recentRuns.count > 8 { snapshots.removeValue(forKey: recentRuns.removeFirst()) }
    }

    private var runID: String?
    private var loadID = UUID()
    private var digests: [String: String] = [:]
    private var values: [String: JSONValue] = [:]
    private var executions: [String: JSONValue] = [:]
    private var executionDigests: [String: String] = [:]

    func load(id: String, useCase: any WorkflowUseCase) async throws -> [String: JSONValue] {
        let generation = UUID()
        loadID = generation
        let (response, isCached) = try await status(id: id, useCase: useCase)
        guard loadID == generation else { throw CancellationError() }
        if isCached { return response }
        if response["monitor_snapshot"]?.boolValue == true {
            let raw = try await WorkflowMonitorSnapshot.read(first: response, id: id, useCase: useCase)
            guard loadID == generation else { throw CancellationError() }
            await seedSnapshot(raw, id: id, generation: generation, useCase: useCase)
            guard loadID == generation else { throw CancellationError() }
            remember(raw, id: id)
            return raw
        }
        return try await loadLegacy(response: response, id: id, generation: generation, useCase: useCase)
    }

    private func status(id: String, useCase: any WorkflowUseCase) async throws -> ([String: JSONValue], Bool) {
        let previous = snapshots[id]
        let hasDigests = previous?["monitor_digests"]?.objectValue != nil
        let options = hasDigests ? ["--monitor-view"] : ["--monitor-view", "--snapshot"]
        let response = try await useCase.command("status", options: options, positionals: [id])
        let stateKeys = ["status", "updated_at", "settling", "draft_revision", "input_decision_id", "revision", "interaction_owner"]
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
        var result = metadata
        for (field, value) in values where field != "execution_index" {
            if value == .null { result.removeValue(forKey: field) } else { result[field] = value }
        }
        result["activations"] = .array(ordered)
        remember(result, id: id)
        return result
    }

    private func loadExecutions(id: String, generation: UUID, useCase: any WorkflowUseCase) async throws -> [JSONValue] {
        let index = WorkflowJSON.objects(values["execution_index"])
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
        for attempt in 0 ... 1 {
            do { return try await readPages(id: id, view: view, expectedDigest: expectedDigest, useCase: useCase) } catch {
                if attempt == 1 { throw error }
            }
        }
        throw PollingError.invalidDetail
    }

    private func readPages(id: String, view: String, expectedDigest: String, useCase: any WorkflowUseCase) async throws -> JSONValue {
        var cursor: String?
        var digest: String?
        var text = ""
        repeat {
            try Task.checkCancellation()
            var options = ["--monitor-view", "--view=\(view)"]
            if let cursor { options.append("--cursor=\(cursor)") }
            let page = try await useCase.command("detail", options: options, positionals: [id])
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
