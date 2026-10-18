import Foundation
import MonitorCore

// MARK: - WorkflowDraftCompletion

/// Reopened editors sharing a draft adopt a late save before their next local write.
@MainActor
struct WorkflowDraftCompletion {
    static var completed: [UUID: WorkflowDraftCompletion] = [:]
    let name: String
    let revision: Int
    let submitted: [String: JSONValue]
    let saved: [String: JSONValue]
}
