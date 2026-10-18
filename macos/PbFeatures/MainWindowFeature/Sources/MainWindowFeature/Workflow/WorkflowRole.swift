import Foundation

// MARK: - WorkflowRole

enum WorkflowRole {
    static let palette = ["start", "planning", "implementation", "review", "task", "workflow", "parallel_group", "end"]
    static func title(_ role: String) -> String {
        switch role {
        case "workflow": "Run workflow"
        case "join": "Wait for all"
        case "parallel_group": "Parallel group"
        case "parallel_start": "Parallel start"
        case "parallel_end": "Parallel end"
        default: role.capitalized
        }
    }

    static func symbol(_ role: String) -> String {
        switch role {
        case "planning": "list.bullet.clipboard"
        case "implementation": "hammer"
        case "review": "checkmark.bubble"
        case "task": "terminal"
        case "workflow": "point.3.connected.trianglepath.dotted"
        case "start": "play"
        case "join", "parallel_end": "arrow.triangle.merge"
        case "parallel_start", "parallel_group": "arrow.triangle.branch"
        case "end": "stop"
        default: "circle"
        }
    }
}
