import Foundation

// MARK: - WorkflowCanvasDropPolicy

enum WorkflowCanvasDropPolicy {
    static func accepts(_ role: String, isEditable: Bool, nodes: [WorkflowNodeModel]) -> Bool {
        guard isEditable, WorkflowRole.palette.contains(role) || role == "join" else { return false }
        return !["start", "end"].contains(role) || !nodes.contains { $0.type == role }
    }
}
