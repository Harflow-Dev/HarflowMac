import SwiftUI

// MARK: - WorkflowUndoCommands

struct WorkflowUndoCommands: ViewModifier {
    let isEnabled: Bool
    let onUndo: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(characters: CharacterSet(charactersIn: "z")) { press in
            guard isEnabled, press.modifiers == .command else { return .ignored }
            onUndo()
            return .handled
        }
    }
}
