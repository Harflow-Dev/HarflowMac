//
//  MessageBoxView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TaskDetailView.swift` (`MessageBox`). The submit decision (which
//  action is eligible, and whether the field clears) lives in `TaskDetailVM.submitMessage(_:)` —
//  this component only owns its own text field, per the screen shape's "components may hold local
//  @State" allowance.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - MessageBoxDisabledReason

/// Why the composer cannot take a message right now, and the copy that explains it (settled plan
/// D7). Kept apart from the view so each reason is a plain, testable mapping.
enum MessageBoxDisabledReason: Equatable {
    /// The run was not started with live input, so nothing can be queued into it.
    case notLiveInput
    /// A person took the session over in Terminal, which now owns the conversation.
    case takenOver
    /// A finished task with no session id to resume.
    case noSession
    /// Running with live input but not accepting messages for another reason.
    case other

    /// The disabled field's text.
    var text: String {
        switch self {
        case .notLiveInput: "Messages are off — this task wasn't started with live input"
        case .takenOver: "Messages are off — you took this task over in Terminal"
        case .noSession: "This task has no session to continue."
        case .other: "Messages are unavailable right now."
        }
    }

    /// Whether the field shows a lock icon: the two "Messages are off" reasons.
    var showsLock: Bool { self == .notLiveInput || self == .takenOver }

    /// The reason a task cannot take Send or Continue. Taken over wins over not-live-input, since it
    /// is the more specific explanation for a run a person is now driving.
    static func reason(for task: TaskInfo) -> MessageBoxDisabledReason {
        if task.status.isRunning {
            if task.takenOver { return .takenOver }
            return task.liveInput ? .other : .notLiveInput
        }
        return .noSession
    }
}

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
    /// Show the lock icon and `placeholder` in place of the text field.
    var isLocked = false

    static let disabled = MessageBoxModel(
        canSend: false, canContinue: false, isBusy: false,
        label: "Messages", hint: "", placeholder: MessageBoxDisabledReason.noSession.text, buttonLabel: "Continue"
    )
}

// MARK: - MessageBoxView

/// "Message this task" while a live-input run is going; "Continue" (a resume) once it settled.
/// Rendered as a floating rounded field at the foot of the centred column, with the hint and the
/// ⌘↩ affordance surfaced underneath it as a caption line.
struct MessageBoxView: View {
    let model: MessageBoxModel
    let onSubmit: (String) -> Bool
    @State private var text = ""

    private var isEnabled: Bool { model.canSend || model.canContinue }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 10) {
                field
                sendButton
            }
            .padding(.leading, 16)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(Color.composerFill))
            .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(isEnabled ? Color.liveDot.opacity(0.4) : Color.cardBorder, lineWidth: 1))
            .shadow(color: .black.opacity(0.08), radius: 6, y: 2)

            if !model.hint.isEmpty {
                Text("\(model.label) · \(model.hint) · ⌘↩ to send")
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 20)
    }

    private var canSubmit: Bool {
        isEnabled && !model.isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// An up-arrow in a filled circle; `buttonLabel` ("Send"/"Continue") is its tooltip and
    /// accessibility label.
    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.pb(.body, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(canSubmit ? Color.accentColor : Color.secondaryText.opacity(0.35)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.return, modifiers: .command)
        .disabled(!canSubmit)
        .help(model.buttonLabel)
        .accessibilityLabel(model.buttonLabel)
    }

    @ViewBuilder
    private var field: some View {
        if model.isLocked {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").accessibilityHidden(true)
                Text(model.placeholder)
            }
            .font(.pb(.body))
            .foregroundStyle(Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        } else {
            TextField(model.placeholder, text: $text, axis: .vertical)
                .lineLimit(1 ... 6)
                .textFieldStyle(.plain)
                .disabled(!isEnabled)
                .onSubmit(submit)
                .padding(.vertical, 4)
        }
    }

    private func submit() {
        if onSubmit(text) { text = "" }
    }
}

#if DEBUG
@MainActor
private func previewStack() -> some View {
    VStack(spacing: 8) {
        MessageBoxView(model: MessageBoxModel(
            canSend: true, canContinue: false, isBusy: false, label: "Message this task",
            hint: "Queued; folded into the current turn or sent after it", placeholder: "Message this task while it runs…",
            buttonLabel: "Send"
        )) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: false, canContinue: true, isBusy: false, label: "Continue this session",
            hint: "Continues the same agent session; the reply appears below as a new turn", placeholder: "Send a follow-up — it continues this conversation",
            buttonLabel: "Continue"
        )) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: false, canContinue: false, isBusy: false, label: "Messages", hint: "",
            placeholder: MessageBoxDisabledReason.notLiveInput.text, buttonLabel: "Send", isLocked: true
        )) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: false, canContinue: false, isBusy: false, label: "Messages", hint: "",
            placeholder: MessageBoxDisabledReason.takenOver.text, buttonLabel: "Send", isLocked: true
        )) { _ in true }
        MessageBoxView(model: .disabled) { _ in true }
    }
    .frame(width: 560)
    .padding(.vertical)
    .background(Color.windowBG)
}

#Preview("Light") {
    previewStack().preferredColorScheme(.light)
}

#Preview("Dark") {
    previewStack().preferredColorScheme(.dark)
}
#endif
