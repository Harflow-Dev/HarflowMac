import Foundation
@testable import MainWindowFeature
import MonitorCore

extension ParallelVMTests {
    func task(
        id: String, backend: String = "claude", status: String = "running", startedAt: Date? = .now,
        group: String? = "g1", freedom: String? = nil, sessionID: String? = "sess-1234567890",
        summary: String? = nil, enforcement: [String: JSONValue]? = nil, parentTaskID: String? = nil
    ) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string(backend), "status": .string(status)
        ]
        if let startedAt { object["started_at"] = .string(ISO8601DateFormatter().string(from: startedAt)) }
        if let group { object["group"] = .string(group) }
        if let freedom { object["freedom"] = .string(freedom) }
        if let sessionID { object["session_id"] = .string(sessionID) }
        if let summary { object["summary"] = .string(summary) }
        if let enforcement { object["enforcement"] = .object(enforcement) }
        if let parentTaskID { object["parent_task_id"] = .string(parentTaskID) }
        return TaskInfo(.object(object))!
    }
    
}
