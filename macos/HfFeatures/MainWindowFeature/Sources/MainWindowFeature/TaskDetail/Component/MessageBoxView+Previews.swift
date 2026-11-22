import HfUI
import SwiftUI

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
