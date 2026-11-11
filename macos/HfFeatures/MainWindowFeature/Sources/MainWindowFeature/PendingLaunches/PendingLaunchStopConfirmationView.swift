import HfUI
import SwiftUI

// MARK: - PendingLaunchStopConfirmationView

/// The Stop confirmation for a pending launch (HarflowDesign 83d820f, `v2/scripts/screens-pending-launches.js`).
/// It never dismisses itself: both actions go to the coordinator, which owns the sheet and the single exit.
struct PendingLaunchStopConfirmationView: View {
    let taskID: String
    let onCancel: () -> Void
    let onConfirm: () -> Void
    @FocusState private var cancelFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: TaskScreenStyle.Dialog.gap) {
            Text("Stop this launch?")
                .font(TaskScreenStyle.sans(size: TaskScreenStyle.Dialog.title.size))
                .fontWeight(TaskScreenStyle.Dialog.titleWeight)
                .lineSpacing(TaskScreenStyle.lineSpacing(TaskScreenStyle.Dialog.title))
                .foregroundStyle(TaskScreenStyle.Colors.text.color)
                .accessibilityAddTraits(.isHeader)
            Text("This asks the engine to stop the full launch ID below. If it starts before the request arrives, the task with this same ID may be stopped.")
                .fixedSize(horizontal: false, vertical: true)
            Text(taskID)
                .font(.hf(.secondary, design: .monospaced))
                .foregroundStyle(TaskScreenStyle.Colors.text.color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("pending-launch-stop-id")
            Text("This is best effort. Files already written remain in place. The engine may refuse Stop because of workflow controls or your access.")
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: TaskScreenStyle.Dialog.actionsGap) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .focused($cancelFocused)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("pending-launch-stop-cancel")
                Button("Request Stop", role: .destructive, action: onConfirm)
                    .accessibilityIdentifier("pending-launch-stop-confirm")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, TaskScreenStyle.Dialog.actionsMarginTop)
        }
        .font(TaskScreenStyle.sans(size: TaskScreenStyle.Dialog.text.size))
        .lineSpacing(TaskScreenStyle.lineSpacing(TaskScreenStyle.Dialog.text))
        .foregroundStyle(TaskScreenStyle.Dialog.textColor.color)
        .padding(TaskScreenStyle.Dialog.padding)
        .frame(width: TaskScreenStyle.Dialog.width)
        .onAppear { cancelFocused = true }
    }
}

#if DEBUG
#Preview("Pending Stop — light") {
    PendingLaunchStopConfirmationView(taskID: PendingLaunchesFixture.detailID, onCancel: {}, onConfirm: {}).preferredColorScheme(.light)
}

#Preview("Pending Stop — dark") {
    PendingLaunchStopConfirmationView(taskID: PendingLaunchesFixture.detailID, onCancel: {}, onConfirm: {}).preferredColorScheme(.dark)
}
#endif
