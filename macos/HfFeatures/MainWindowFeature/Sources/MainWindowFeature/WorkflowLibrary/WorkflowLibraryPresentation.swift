import Foundation
import HfRepository

// MARK: - WorkflowLibraryRow

struct WorkflowLibraryRow: Identifiable, Equatable, Sendable {
    var id: String { name }
    let name: String
    let description: String?
    let nodeCount: Int?
    let context: WorkflowResponseContext
    let mount: UUID
}

// MARK: - WorkflowLibraryPresentation

struct WorkflowLibraryPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case loading, empty, loaded, failed }
    var phase: Phase = .loading
    var rows: [WorkflowLibraryRow] = []
    var error: String?

    nonisolated static func rows(_ records: [WorkflowRecord], context: WorkflowResponseContext, mount: UUID) throws -> [WorkflowLibraryRow] {
        try records.map { record in
            try Task.checkCancellation()
            let description = record.definition["description"]?.stringValue ?? record.raw["description"]?.stringValue
            return WorkflowLibraryRow(name: record.id, description: description?.isEmpty == false ? description : nil,
                                      nodeCount: record.definition["nodes"]?.arrayValue?.count, context: context, mount: mount)
        }
    }
}
