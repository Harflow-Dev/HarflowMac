import Foundation
import MonitorCore

// MARK: - WorkflowMonitorSnapshot

/// Reads one immutable CLI transport snapshot, even while its source run advances.
@MainActor
struct WorkflowMonitorSnapshot {
    static func read(first: [String: JSONValue], id: String, useCase: any WorkflowUseCase) async throws -> [String: JSONValue] {
        var page = first
        var text = ""
        let digest = first["content_sha256"]?.stringValue
        let total = first["total_characters"]?.intValue
        repeat {
            try Task.checkCancellation()
            guard page["workflow_run_id"]?.stringValue == id,
                  let chunk = page["chunk"]?.stringValue,
                  digest != nil, page["content_sha256"]?.stringValue == digest,
                  let total, page["total_characters"]?.intValue == total,
                  page["offset"]?.intValue == text.utf8.count,
                  !chunk.isEmpty else { throw SnapshotError.invalidPage }
            text += chunk
            guard text.utf8.count <= total else { throw SnapshotError.invalidPage }
            guard let cursor = page["next_cursor"]?.stringValue else { break }
            page = try await useCase.command("status", options: ["--monitor-view", "--snapshot", "--cursor=\(cursor)"], positionals: [id])
        } while true
        guard text.utf8.count == total, let raw = JSONValue.parse(Data(text.utf8))?.objectValue,
              raw["workflow_run_id"]?.stringValue == id else { throw SnapshotError.invalidPage }
        return raw
    }

    private enum SnapshotError: LocalizedError {
        case invalidPage
        var errorDescription: String? { "The workflow snapshot could not be loaded. Refresh to try again." }
    }
}
