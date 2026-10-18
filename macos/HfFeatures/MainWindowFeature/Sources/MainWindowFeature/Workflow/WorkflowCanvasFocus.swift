import SwiftUI

// MARK: - WorkflowCanvas keyboard focus

extension WorkflowCanvas {
    func deletePreservingCanvasFocus() {
        // Deleting a focused node removes its native responder. Transfer focus after SwiftUI
        // has removed the node so the next keyboard command still reaches the graph.
        isCanvasFocused = false
        onDelete()
        Task { @MainActor in
            await Task.yield()
            isCanvasFocused = true
        }
    }
}
