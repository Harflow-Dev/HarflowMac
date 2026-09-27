//
//  MessageBoxView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TaskDetailView.swift` (`MessageBox`). The submit decision (which
//  action is eligible, and whether the field clears) lives in `TaskDetailVM.submitMessage(_:)` —
//  this component only owns its own text field, per the screen shape's "components may hold local
//  @State" allowance.
//

import PbUI
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
/// Rendered as a raised composer card — a place to write, not a footer bar — with the hint and
/// the ⌘↩ affordance surfaced underneath it as a caption line.
struct MessageBoxView: View {
    let model: MessageBoxModel
    let onSubmit: (String) -> Bool
    @State private var text = ""

    private var isEnabled: Bool { model.canSend || model.canContinue }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 8) {
                TextField(model.placeholder, text: $text, axis: .vertical)
                    .lineLimit(2 ... 6)
                    .textFieldStyle(.plain)
                    .disabled(!isEnabled)
                    .onSubmit(submit)
                HStack {
                    Text(model.label).font(.pb(.secondary, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.buttonLabel, action: submit)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!isEnabled || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isBusy)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isEnabled ? Color.accentColor.opacity(0.35) : Color.hairline, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.1), radius: 5, y: 2)

            if !model.hint.isEmpty {
                Text("\(model.hint) · ⌘↩ to send")
                    .font(.pb(.caption))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }

    private func submit() {
        if onSubmit(text) { text = "" }
    }
}

#if DEBUG
@MainActor
private func previewStack() -> some View {
    VStack(spacing: 20) {
        MessageBoxView(model: MessageBoxModel(
            canSend: true, canContinue: false, isBusy: false, label: "Message this task",
            hint: "Queued; folded into the current turn or sent after it", placeholder: "Message this task while it runs…",
            buttonLabel: "Send"
        )) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: false, canContinue: true, isBusy: false, label: "Continue this task",
            hint: "Resumes the session with this message", placeholder: "Continue this task…",
            buttonLabel: "Continue"
        )) { _ in true }
        MessageBoxView(model: .disabled) { _ in true }
    }
    .padding()
    .frame(width: 500)
}

#Preview("Light") {
    previewStack().preferredColorScheme(.light)
}

#Preview("Dark") {
    previewStack().preferredColorScheme(.dark)
}
#endif
