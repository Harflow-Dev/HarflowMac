//
//  MessageBoxView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TaskDetailView.swift` (`MessageBox`). The submit decision (which
//  action is eligible, and whether the field clears) lives in `TaskDetailVM.submitMessage(_:)` —
//  this component only owns its own text field, per the screen shape's "components may hold local
//  @State" allowance.
//

import SwiftUI

// MARK: - MessageBoxModel

/// Presentation data for the message box: whether Send/Continue is eligible right now, and the
/// exact copy for each state.
struct MessageBoxModel {
    let canSend: Bool
    let canContinue: Bool
    let isBusy: Bool
    let label: String
    let hint: String
    let placeholder: String
    let buttonLabel: String
    
    static let disabled = MessageBoxModel(
        canSend: false, canContinue: false, isBusy: false,
        label: "Messages", hint: "", placeholder: "This task has no session to continue.", buttonLabel: "Continue"
    )
}

// MARK: - MessageBoxView

/// "Message this task" while a live-input run is going; "Continue" (a resume) once it settled.
struct MessageBoxView: View {
    let model: MessageBoxModel
    let onSubmit: (String) -> Bool
    @State private var text = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(model.label).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(model.hint).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                TextField(model.placeholder, text: $text, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!(model.canSend || model.canContinue))
                    .onSubmit(submit)
                Button(model.buttonLabel, action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!(model.canSend || model.canContinue) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
    
    private func submit() {
        if onSubmit(text) { text = "" }
    }
}

#if DEBUG
#Preview {
    VStack(spacing: 20) {
        MessageBoxView(model: MessageBoxModel(
            canSend: true, canContinue: false, isBusy: false, label: "Message this task",
            hint: "Queued; folded into the current turn or sent after it", placeholder: "Message this task while it runs…",
            buttonLabel: "Send"
        )) { _ in true }
        MessageBoxView(model: .disabled) { _ in true }
    }
    .padding()
    .frame(width: 500)
}
#endif
