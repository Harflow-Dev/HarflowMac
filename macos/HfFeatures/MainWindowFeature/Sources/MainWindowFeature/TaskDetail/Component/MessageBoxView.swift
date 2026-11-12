//
//  MessageBoxView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TaskDetailView.swift` (`MessageBox`). The submit decision (which
//  action is eligible, and whether the field clears) lives in `TaskDetailVM.submitMessage(_:)` —
//  this component only owns its own text field, per the screen shape's "components may hold local
//  @State" allowance. A caller that must keep the draft across navigation passes `text`, an external binding
//  (the standalone task's `TaskDraftStore`); without it the draft stays in local @State, as before.
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
    var isStopping = false
    /// Optional task-level Stop action, rendered only by the transcript composer.
    var stopAction: (@MainActor () -> Void)?

    /// Allows retaining an editable draft while submission waits for current status authority.
    var allowsDraftEditing = false
    /// The field's accessibility label when it differs from the placeholder ("Message Codex"). `nil` keeps the placeholder.
    var fieldAccessibilityLabel: String?
    /// The send button's accessibility label when it differs from `buttonLabel` ("Send to Codex").
    var sendAccessibilityLabel: String?
    var canEditDraft: Bool { canSend || canContinue || allowsDraftEditing }

    /// The printed hint under an enabled composer: the guaranteed shortcut, after the model's hint when it has one.
    var printedHint: String { hint.isEmpty ? "⌘↩ to send" : hint + " · ⌘↩ to send" }

    static let disabled = MessageBoxModel(
        canSend: false, canContinue: false, isBusy: false,
        label: "Messages", hint: "", placeholder: MessageBoxDisabledReason.noSession.text, buttonLabel: "Continue"
    )
}

// MARK: - MessageBoxStyle

/// The composer's presentation. `.standard` is the glass capsule every surface had before the task screen's
/// metrics and the default everywhere; `.transcript` applies `TaskScreenStyle.Composer` and `ComposerWrapper`
/// and is requested only by the standalone task and Group mounts of the task detail.
enum MessageBoxStyle: Equatable {
    case standard
    case transcript
    /// The Parallel lane's composer (`.hd-composer` in `.hd-lane__foot`): the transcript surface in one row of a
    /// field and a 28 pt send button, padding 8/8/8/12. It never draws Send now, a printed hint, Stop, the wrapper
    /// padding or the 696 cap; lanes queue only.
    case lane

    /// The transcript composer's "Send now" size (13 pt); not part of `TaskScreenStyle.Composer`.
    static let sendNowSize: CGFloat = 13
    /// The transcript composer's printed hint size (12 pt); not part of `TaskScreenStyle.Composer`.
    static let hintSize: CGFloat = 12
}

// MARK: - UndimmedButtonStyle

/// Returns the label as is. `.plain` dims a disabled button, which would blend the transcript send button's
/// disabled fill with the page; the transcript chooses every state's colours itself.
private struct UndimmedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - TranscriptComposerHint

/// The transcript composer's printed hint, shared with the skeleton so the two reserve the same row.
struct TranscriptComposerHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(TaskScreenStyle.sans(size: MessageBoxStyle.hintSize))
            .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
            .padding(.leading, TaskScreenStyle.Composer.paddingLeading)
    }
}

// MARK: - TranscriptComposerSurface

/// `.hd-composer`'s surface: `surface` fill, 1 pt `border`, and the two `--shadow-composer` layers in black ink.
/// Shared with the loading skeleton's composer placeholder so the two cannot drift.
struct TranscriptComposerSurface: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let composer = TaskScreenStyle.Composer.self
        let shape = RoundedRectangle(cornerRadius: composer.cornerRadius)
        ZStack {
            ForEach(Array(composer.shadow.enumerated()), id: \.offset) { _, layer in
                shape.fill(composer.fill.color)
                    .shadow(
                        color: Color.shadow.opacity(colorScheme == .dark ? layer.darkOpacity : layer.lightOpacity),
                        // CSS blur is the full blur diameter; SwiftUI's radius is half of it.
                        radius: layer.blur / 2,
                        y: layer.offsetY
                    )
            }
            shape.strokeBorder(composer.borderColor.color, lineWidth: composer.borderWidth)
        }
    }
}

// MARK: - MessageBoxView

/// "Message this task" while a live-input run is going; "Continue" (a resume) once it settled.
/// The redesign's composer (§3/§6.2). `.standard` is a rounded-18 Liquid Glass capsule with a circular
/// 32 pt `accentFill` send button; `.transcript` is the task screen's `.hd-composer` (an opaque surface with
/// a border, two shadow layers and a `TaskScreenStyle` send button). The submit decision and every guard stay
/// with the VM; this component still owns only its own text field. The printed hint is the guaranteed ⌘↩
/// shortcut the send button already declares — it must not imply a new key behavior.
///
/// The draft lives in local @State unless the caller passes `text`: then every read and write (typing, both submit
/// paths, the clear after an admitted send) goes through that binding and nothing is kept locally.
struct MessageBoxView: View {
    let model: MessageBoxModel
    var onSubmitNow: ((String) -> Bool)?
    var isCompact = false
    var style: MessageBoxStyle = .standard
    /// An external home for the draft; `nil` keeps it in local state.
    var text: Binding<String>?
    let onSubmit: (String) -> Bool
    @State private var localText = ""
    @State private var isHoveringSend = false
    @FocusState private var fieldFocused: Bool
    private var isEnabled: Bool { model.canSend || model.canContinue }
    private var draft: Binding<String> { text ?? $localText }

    var body: some View {
        switch style {
        case .standard: standardBody
        case .transcript: transcriptBody
        case .lane: laneBody
        }
    }

    // MARK: Lane

    /// `.hd-composer` in a lane: padding `space-2 space-2 space-2 space-3`, one row, the field at least 24 pt tall
    /// (40 pt when locked) and a 28 pt send button, so the row is 44 pt (56 pt locked).
    private var laneBody: some View {
        HStack(spacing: TaskScreenStyle.Composer.gap) {
            laneField
            laneSendButton
        }
        .padding(.top, TaskScreenStyle.Scale.space2)
        .padding(.trailing, TaskScreenStyle.Scale.space2)
        .padding(.bottom, TaskScreenStyle.Scale.space2)
        .padding(.leading, TaskScreenStyle.Scale.space3)
        .background { TranscriptComposerSurface() }
    }

    static let laneSendSize: CGFloat = 28
    static let laneFieldMinHeight: CGFloat = 24
    static let laneLockedFieldMinHeight: CGFloat = 40

    @ViewBuilder private var laneField: some View {
        let composer = TaskScreenStyle.Composer.self
        if model.isLocked {
            HStack(spacing: HfRadius.Metrics.spacing8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                    .accessibilityHidden(true)
                Text(model.placeholder)
            }
            .font(TaskScreenStyle.sans(size: composer.inputText.size))
            .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
            .frame(maxWidth: .infinity, minHeight: Self.laneLockedFieldMinHeight, alignment: .leading)
            .accessibilityElement(children: .combine)
        } else {
            TextField("", text: draft, axis: .vertical)
                .focused($fieldFocused)
                .scrollChromeScope()
                .accessibilityLabel(model.fieldAccessibilityLabel ?? model.placeholder)
                .lineLimit(1 ... 6)
                .textFieldStyle(.plain)
                .font(TaskScreenStyle.sans(size: composer.inputText.size))
                .overlay(alignment: .leading) {
                    if draft.wrappedValue.isEmpty {
                        Text(model.placeholder)
                            .font(TaskScreenStyle.sans(size: composer.inputText.size))
                            .foregroundStyle(composer.placeholderColor.color)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(composer.inputColor.color)
                .disabled(!model.canEditDraft)
                .onSubmit(submit)
                .frame(minHeight: Self.laneFieldMinHeight)
        }
    }

    /// The 28 pt send circle; ⌘↩ binds only while the field is focused.
    @ViewBuilder private var laneSendButton: some View {
        let composer = TaskScreenStyle.Composer.self
        let fill = canSubmit ? (isHoveringSend ? composer.sendHoverFill : composer.sendFill) : composer.sendDisabledFill
        let button = Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.hf(.body, weight: .bold))
                .foregroundStyle((canSubmit ? composer.sendForeground : composer.sendDisabledForeground).color)
                .frame(width: Self.laneSendSize, height: Self.laneSendSize)
                .background(Circle().fill(fill.color))
                .contentShape(Circle())
        }
        .buttonStyle(UndimmedButtonStyle())
        .disabled(!canSubmit)
        .onHover { isHoveringSend = $0 }
        .help("\(model.buttonLabel) (⌘↩)")
        .accessibilityLabel(model.sendAccessibilityLabel ?? model.buttonLabel)
        if fieldFocused { button.keyboardShortcut(.return, modifiers: .command) } else { button }
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            controls
            .padding(.horizontal, isCompact ? HfRadius.Metrics.spacing12 : HfRadius.Metrics.spacing16)
            .padding(.vertical, HfRadius.Metrics.spacing12)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: HfRadius.Metrics.composerCornerRadius))
            if isEnabled {
                Text(model.printedHint)
                    .font(.hf(.caption))
                    .foregroundStyle(Color.tertiaryText)
                    .padding(.leading, HfRadius.Metrics.spacing16)
            }
        }
        .padding(.horizontal, isCompact ? HfRadius.Metrics.spacing8 : HfRadius.Metrics.spacing24)
        .padding(.top, HfRadius.Metrics.spacing12)
        .padding(.bottom, HfRadius.Metrics.spacing20)
    }

    /// `.hd-composer` inside its task-screen wrapper. The wrapper is clear so the page background shows.
    private var transcriptBody: some View {
        let composer = TaskScreenStyle.Composer.self
        let wrapper = TaskScreenStyle.ComposerWrapper.self
        return VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            controls
                .padding(.top, composer.paddingTop)
                .padding(.trailing, composer.paddingTrailing)
                .padding(.bottom, composer.paddingBottom)
                .padding(.leading, composer.paddingLeading)
                .background { TranscriptComposerSurface() }
            if isEnabled {
                TranscriptComposerHint(text: model.printedHint)
            }
        }
        .padding(.horizontal, wrapper.paddingHorizontal)
        .padding(.top, wrapper.paddingTop)
        .padding(.bottom, wrapper.paddingBottom)
        .frame(maxWidth: wrapper.maxWidth)
        .frame(maxWidth: .infinity)
    }

    private var canSubmit: Bool {
        isEnabled && !model.isBusy && !draft.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// Standard splices the buttons into the caller's row; the transcript groups them `Composer.barGap` apart.
    @ViewBuilder private var actions: some View {
        switch style {
        case .standard: actionButtons
        case .transcript, .lane:
            HStack(spacing: TaskScreenStyle.Composer.barGap) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if style == .transcript, let stopAction = model.stopAction {
            Button(action: stopAction) { Label(model.isStopping ? "Stopping…" : "Stop", systemImage: "stop.fill") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy || model.isStopping)
                .accessibilityIdentifier("task-composer.stop")
        }
        if let onSubmitNow {
            sendNowButton(onSubmitNow)
        }
        if !isCompact || fieldFocused {
            sendButton.keyboardShortcut(.return, modifiers: .command)
        } else {
            sendButton
        }
    }

    @ViewBuilder
    private func sendNowButton(_ onSubmitNow: @escaping (String) -> Bool) -> some View {
        switch style {
        case .standard:
            Button("Send now") { if onSubmitNow(draft.wrappedValue) { draft.wrappedValue = "" } }
                .buttonStyle(.plain)
                .foregroundStyle(sendNowColor)
                .disabled(!canSubmit)
                .help("Ask for immediate delivery; an engine refusal keeps the message queued")
        case .transcript, .lane:
            Button("Send now") { if onSubmitNow(draft.wrappedValue) { draft.wrappedValue = "" } }
                .buttonStyle(UndimmedButtonStyle())
                .font(TaskScreenStyle.sans(size: MessageBoxStyle.sendNowSize))
                .foregroundStyle(sendNowColor)
                .disabled(!canSubmit)
                .help("Ask for immediate delivery; an engine refusal keeps the message queued")
        }
    }

    private var sendNowColor: Color {
        switch style {
        case .standard: canSubmit ? Color.primaryText : Color.tertiaryText
        case .transcript, .lane: (canSubmit ? TaskScreenStyle.Colors.text : TaskScreenStyle.Colors.textTertiary).color
        }
    }

    /// The send button: a circular `accentFill` button (§6.2) in the standard style, a `Composer.send*` circle in
    /// the transcript style. `buttonLabel` ("Send"/"Continue") is its tooltip and accessibility label in both, and
    /// the printed ⌘↩ hint matches the shortcut it declares.
    @ViewBuilder private var sendButton: some View {
        switch style {
        case .standard: standardSendButton
        case .transcript, .lane: transcriptSendButton
        }
    }

    private var transcriptSendButton: some View {
        let composer = TaskScreenStyle.Composer.self
        let fill = canSubmit
            ? (isHoveringSend ? composer.sendHoverFill : composer.sendFill)
            : composer.sendDisabledFill
        return Button(action: submit) {
            Image(systemName: "arrow.up")
                .font(.hf(.body, weight: .bold))
                .foregroundStyle((canSubmit ? composer.sendForeground : composer.sendDisabledForeground).color)
                .frame(width: composer.sendSize, height: composer.sendSize)
                .background(Circle().fill(fill.color))
                .contentShape(Circle())
        }
        .buttonStyle(UndimmedButtonStyle())
        .disabled(!canSubmit)
        .onHover { isHoveringSend = $0 }
        .help("\(model.buttonLabel) (⌘↩)")
        .accessibilityLabel(model.buttonLabel)
    }

    private var standardSendButton: some View {
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
        switch style {
        case .standard: standardField
        case .transcript, .lane: transcriptField
        }
    }

    @ViewBuilder
    private var transcriptField: some View {
        let composer = TaskScreenStyle.Composer.self
        if model.isLocked {
            HStack(spacing: HfRadius.Metrics.spacing8) {
                Image(systemName: "lock.fill").accessibilityHidden(true)
                Text(model.placeholder)
            }
            .font(TaskScreenStyle.sans(size: composer.inputText.size))
            .lineSpacing(TaskScreenStyle.lineSpacing(composer.inputText))
            .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, composer.inputPaddingVertical)
            .frame(minHeight: composer.inputMinHeight)
            .accessibilityElement(children: .combine)
        } else {
            // macOS ignores a `prompt:` foreground colour, so the placeholder is an overlay in
            // `Composer.placeholderColor`. The title is empty; VoiceOver gets the placeholder as the label.
            // No `.lineSpacing`: it has no effect on a vertical-axis `TextField` (measured 17 pt per line,
            // not the design's 22), a recorded deviation pending an editor swap.
            TextField("", text: draft, axis: .vertical)
                .focused($fieldFocused)
                .scrollChromeScope()
                .accessibilityLabel(model.placeholder)
                .accessibilityHint(model.hint)
                .lineLimit(1 ... 6)
                .textFieldStyle(.plain)
                .font(TaskScreenStyle.sans(size: composer.inputText.size))
                .overlay(alignment: .topLeading) {
                    if draft.wrappedValue.isEmpty {
                        Text(model.placeholder)
                            .font(TaskScreenStyle.sans(size: composer.inputText.size))
                            .foregroundStyle(composer.placeholderColor.color)
                            .lineLimit(1)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            .foregroundStyle(composer.inputColor.color)
            .disabled(!model.canEditDraft)
            .onSubmit(submit)
            .padding(.vertical, composer.inputPaddingVertical)
            .frame(minHeight: composer.inputMinHeight)
        }
    }

    @ViewBuilder
    private var standardField: some View {
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
            TextField(model.placeholder, text: draft, axis: .vertical)
                .focused($fieldFocused)
                // Bounded scope (§6.2): the multiline composer's own dedicated scroll view, when
                // one exists, carries thin overlay chrome; a field with none stays a quiet no-op,
                // and the shared field editor is never targeted. The outer pane is untouched.
                .scrollChromeScope()
                .accessibilityHint(model.hint)
                .lineLimit(1 ... 6)
                .textFieldStyle(.plain)
                .disabled(!model.canEditDraft)
                .onSubmit(submit)
                .padding(.vertical, HfRadius.Metrics.spacing4)
        }
    }

    private func submit() {
        if onSubmit(draft.wrappedValue) { draft.wrappedValue = "" }
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

@MainActor
private func transcriptPreviewStack() -> some View {
    VStack(spacing: HfRadius.Metrics.spacing8) {
        MessageBoxView(model: MessageBoxModel(
            canSend: true, canContinue: false, isBusy: false, label: "Message this task",
            hint: "Send queues; Send now requests immediate delivery when safe", placeholder: "Queue a message…",
            buttonLabel: "Send"
        ), onSubmitNow: { _ in true }, style: .transcript) { _ in true }
        MessageBoxView(model: MessageBoxModel(
            canSend: false, canContinue: false, isBusy: false, label: "Messages", hint: "",
            placeholder: MessageBoxDisabledReason.takenOver.text, buttonLabel: "Send", isLocked: true
        ), style: .transcript) { _ in true }
        MessageBoxView(model: .disabled, style: .transcript) { _ in true }
    }
    .frame(width: TaskScreenStyle.ComposerWrapper.maxWidth)
    .padding(.vertical, HfRadius.Metrics.spacing16)
    .background(TaskScreenStyle.Colors.pageBackground.color)
}

#Preview("Light") {
    previewStack().preferredColorScheme(.light)
}

#Preview("Dark") {
    previewStack().preferredColorScheme(.dark)
}

#Preview("Transcript, light") {
    transcriptPreviewStack().preferredColorScheme(.light)
}

#Preview("Transcript, dark") {
    transcriptPreviewStack().preferredColorScheme(.dark)
}
#endif
