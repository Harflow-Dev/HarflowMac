import Foundation
import MonitorCore

// MARK: - WorkflowRunPolling

/// Reassembles changed authoritative views without repeatedly transferring old results.
@MainActor
final class WorkflowRunPolling {
    private var runID: String?
    private var loadID = UUID()
    private var digests: [String: String] = [:]
    private var values: [String: JSONValue] = [:]
    private var executions: [String: JSONValue] = [:]
    private var executionDigests: [String: String] = [:]

    func load(id: String, useCase: any WorkflowUseCase) async throws -> [String: JSONValue] {
        let generation = UUID()
        loadID = generation
        let response = try await useCase.command("status", options: ["--monitor-view"], positionals: [id])
        guard loadID == generation else { throw CancellationError() }
        let metadata = response["run"]?.objectValue ?? response
        // Preview fixtures and old CLI responses retain their existing complete shape.
        guard let advertised = metadata["monitor_digests"]?.objectValue else { return metadata }
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
            var options = ["--view=\(view)"]
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
        var errorDescription: String? { "Workflow details changed while loading. Refreshing the latest revision." }
    }
}
