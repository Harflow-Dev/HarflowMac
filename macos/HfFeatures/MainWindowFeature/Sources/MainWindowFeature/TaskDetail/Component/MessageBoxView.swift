//
//  MessageBoxView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TaskDetailView.swift` (`MessageBox`). The submit decision (which
//  action is eligible, and whether the field clears) lives in `TaskDetailVM.submitMessage(_:)` —
//  this component only owns its own text field, per the screen shape's "components may hold local
//  @State" allowance.
//

import HfUI
import MonitorCore
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
/// The redesign's composer (§3/§6.2): a rounded-18 Liquid Glass capsule with a circular 32 pt
/// `accentFill` send button. The submit decision and every guard stay with the VM; this component
/// still owns only its own text field. The printed hint is the guaranteed ⌘↩ shortcut the send
/// button already declares — it must not imply a new key behavior.
struct MessageBoxView: View {
    let model: MessageBoxModel
    var onSubmitNow: ((String) -> Bool)?
    var isCompact = false
    let onSubmit: (String) -> Bool
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private var isEnabled: Bool { model.canSend || model.canContinue }

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            controls
            .padding(.horizontal, isCompact ? HfRadius.Metrics.spacing12 : HfRadius.Metrics.spacing16)
            .padding(.vertical, HfRadius.Metrics.spacing12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: HfRadius.Metrics.composerCornerRadius))
            if isEnabled {
                Text(model.hint.isEmpty ? "⌘↩ to send" : model.hint + " · ⌘↩ to send")
                    .font(.hf(.caption))
                    .foregroundStyle(Color.tertiaryText)
                    .padding(.leading, HfRadius.Metrics.spacing16)
            }
        }
        .padding(.horizontal, isCompact ? HfRadius.Metrics.spacing8 : HfRadius.Metrics.spacing24)
        .padding(.top, HfRadius.Metrics.spacing12)
        .padding(.bottom, HfRadius.Metrics.spacing20)
    }

    private var canSubmit: Bool {
        isEnabled && !model.isBusy && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder private var controls: some View {
        if isCompact {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: HfRadius.Metrics.spacing10) {
                    field.frame(minWidth: 120)
                    actions
                }
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                    field
                    HStack(spacing: HfRadius.Metrics.spacing10) {
                        Spacer(minLength: 0)
                        actions
                    }
                }
            }
        } else {
            HStack(spacing: HfRadius.Metrics.spacing10) {
                field
                actions
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if let onSubmitNow {
            Button("Send now") { if onSubmitNow(text) { text = "" } }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmit ? Color.primaryText : Color.tertiaryText)
                .disabled(!canSubmit)
                .help("Ask for immediate delivery; an engine refusal keeps the message queued")
        }
        if !isCompact || fieldFocused {
            sendButton.keyboardShortcut(.return, modifiers: .command)
        } else {
            sendButton
        }
    }

    /// A circular 32 pt `accentFill` button (§6.2); `buttonLabel` ("Send"/"Continue") is its tooltip
    /// and accessibility label, and the printed ⌘↩ hint matches the shortcut it declares.
    private var sendButton: some View {
        Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.hf(.body, weight: .bold))
                .foregroundStyle(Color.onAccent)
                .frame(
                    width: HfRadius.Metrics.composerSendButtonSize,
                    height: HfRadius.Metrics.composerSendButtonSize
                )
                .background(Circle().fill(canSubmit ? Color.accentFill : Color.secondaryText.opacity(0.35)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canSubmit)
        .help("\(model.buttonLabel) (⌘↩)")
        .accessibilityLabel(model.buttonLabel)
    }

    @ViewBuilder
    private var field: some View {
        if model.isLocked {
            HStack(spacing: HfRadius.Metrics.spacing8) {
                Image(systemName: "lock.fill").accessibilityHidden(true)
                Text(model.placeholder)
            }
            .font(.hf(.body))
            .foregroundStyle(Color.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, HfRadius.Metrics.spacing4)
            .accessibilityElement(children: .combine)
        } else {
            TextField(model.placeholder, text: $text, axis: .vertical)
                .focused($fieldFocused)
                // Bounded scope (§6.2): the multiline composer's own dedicated scroll view, when
                // one exists, carries thin overlay chrome; a field with none stays a quiet no-op,
                // and the shared field editor is never targeted. The outer pane is untouched.
                .scrollChromeScope()
                .accessibilityHint(model.hint)
                .lineLimit(1 ... 6)
                .textFieldStyle(.plain)
                .disabled(!isEnabled)
                .onSubmit(submit)
                .padding(.vertical, HfRadius.Metrics.spacing4)
        }
    }

    private func submit() {
        if onSubmit(text) { text = "" }
    }
}

#if DEBUG
@MainActor
private func previewStack() -> some View {
    VStack(spacing: HfRadius.Metrics.spacing8) {
        MessageBoxView(model: MessageBoxModel(
            canSend: true, canContinue: false, isBusy: false, label: "Message this task",
            hint: "Send queues; Send now requests immediate delivery when safe", placeholder: "Queue a message…",
            buttonLabel: "Send"
        )) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: true, canContinue: false, isBusy: true, label: "Message this task",
            hint: "Send queues; Send now requests immediate delivery when safe", placeholder: "Queue a message…",
            buttonLabel: "Send"
        )) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: true, canContinue: false, isBusy: false, label: "Message this settled task",
            hint: "Send queues; Send now starts a continuation when safe", placeholder: "Queue a message…",
            buttonLabel: "Send"
        )) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: true, canContinue: false, isBusy: false, label: "Message this task without live input",
            hint: "Queued for the next continuation", placeholder: "Queue a message…", buttonLabel: "Send"
        )) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: false, canContinue: false, isBusy: false, label: "Messages", hint: "",
            placeholder: MessageBoxDisabledReason.takenOver.text, buttonLabel: "Send", isLocked: true
        )) { _ in true }
        MessageBoxView(model: .disabled) { _ in true }
    }
    .frame(width: HfRadius.Metrics.taskComponentPreviewWidth)
    .padding(.vertical, HfRadius.Metrics.spacing16)
    .background(Color.windowBG)
}

#Preview("Light") {
    previewStack().preferredColorScheme(.light)
}

#Preview("Dark") {
    previewStack().preferredColorScheme(.dark)
}
#endif
