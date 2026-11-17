import Foundation
import MonitorCore

// MARK: - WorkflowDefinitionCatalog

/// Immutable validation result shared by catalog consumers. Record order and full payloads are retained.
enum WorkflowDefinitionCatalog: Sendable {
    case preparing
    case blocked(String?)
    case ready([WorkflowRecord])

    nonisolated static func prepare(_ response: [String: JSONValue]) throws -> Self {
        try Task.checkCancellation()
        let state = CatalogState(raw: response)
        switch state.status {
        case .preparing: return .preparing
        case .blocked: return .blocked(state.reason)
        case .ready: break
        }
        guard let items = response["workflows"]?.arrayValue else { throw ReadError.incomplete }
        var names: Set<String> = []
        var records: [WorkflowRecord] = []
        records.reserveCapacity(items.count)
        for value in items {
            try Task.checkCancellation()
            guard let object = value.objectValue, let name = object["name"]?.stringValue,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  names.insert(name).inserted else { throw ReadError.incomplete }
            records.append(WorkflowRecord(raw: object))
        }
        try Task.checkCancellation()
        return .ready(records)
    }

    enum ReadError: Error {
        case incomplete
    }
}

// MARK: - WorkflowCatalogPreparation

/// Owns the background isolation and parent-cancellation bridge for pure catalog work.
enum WorkflowCatalogPreparation {
    nonisolated static func start(
        _ response: [String: JSONValue],
        prepare: @escaping @Sendable ([String: JSONValue]) async throws -> WorkflowDefinitionCatalog = { try WorkflowDefinitionCatalog.prepare($0) }
    ) -> Task<WorkflowDefinitionCatalog, Error> {
        Task.detached { try await prepare(response) }
    }

    nonisolated static func value(of task: Task<WorkflowDefinitionCatalog, Error>) async throws -> WorkflowDefinitionCatalog {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
