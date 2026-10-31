import Foundation
import MonitorCore

// MARK: - TaskDetailResourceContext

/// Maps only the current member's public task snapshot; no resource observation lease or task poll.
enum TaskDetailResourceContext {
    static func prepare(taskID: String, raw: [String: JSONValue]) -> TaskResourceContext? {
        switch TaskPhaseSlotsContext.decode(taskID: taskID, raw: raw) {
        case .hidden: return nil
        case .unavailable(_, let diagnostic):
            return .init(title: "Resource context unavailable", message: diagnostic, detail: nil, blockers: nil)
        case .leases(let leases):
            guard let lease = leases.first else { return nil }
            let title: String
            let message: String
            switch lease.state {
            case "released", "expired", "resolved": return nil
            case "queued":
                title = "Waiting for \(lease.name)"
                message = lease.position.map { "Queue position \($0) in the phase observation." } ?? "Waiting; queue position is unavailable."
            case "held":
                title = "Holding \(lease.name)"
                message = "Capacity remains reserved for this task."
            case "cleanup_pending", "cleanup_running", "cleanup_failed", "cleanup_uncertain":
                title = "Cleanup for \(lease.name)"
                message = ResourceSlotsAssembly.stateLabel(lease.state) + "."
            default:
                return .init(title: "Resource context unavailable",
                             message: "The engine reported an unrecognized phase state.", detail: lease.diagnostic, blockers: nil)
            }
            let since = ResourceSlotsAssembly.since(lease.cleanupStartedAt ?? lease.grantedAt ?? lease.enqueuedAt)
            let overcommit = lease.overcommitted == true ? "Phase observation reports overcommit." : nil
            let detail = [since, lease.diagnostic, overcommit].compactMap(\.self).joined(separator: " · ")
            return .init(title: title, message: message, detail: detail.isEmpty ? nil : detail,
                         blockers: lease.state == "queued" ? ResourceSlotsAssembly.blockers(lease) : nil)
        }
    }
}
