import SwiftUI

// MARK: - TaskStopConfirmation

/// A captured task target and the task-list evidence shown before requesting cancellation.
struct TaskStopConfirmation: Identifiable {
    let id: UUID = .init()
    let conversationID: String
    let taskID: String
    let notStoppedTitles: [String]
    let confirm: @MainActor () -> Void
}

// MARK: - TaskStopConfirmationView

/// Approved M05 Stop copy (HarflowDesign 17739e4, `v2/scripts/m05-proposal.js`).
struct TaskStopConfirmationView: View {
    let confirmation: TaskStopConfirmation
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var keepRunningFocused: Bool
    @State private var contentHeight: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: TaskScreenStyle.Dialog.gap) {
            Text("Stop this task?")
                .font(TaskScreenStyle.sans(size: TaskScreenStyle.Dialog.title.size))
                .fontWeight(TaskScreenStyle.Dialog.titleWeight)
                .lineSpacing(TaskScreenStyle.lineSpacing(TaskScreenStyle.Dialog.title))
                .foregroundStyle(TaskScreenStyle.Colors.text.color)
                .accessibilityAddTraits(.isHeader)
            ScrollView {
                VStack(alignment: .leading, spacing: TaskScreenStyle.Dialog.gap) {
                    Text("Harflow asks this run and the tasks it started through Harflow to stop. This is best effort.")
                    bullet("Files already written stay in place.")
                    bullet("Builds and other background processes the run started can keep running. Harflow can't list them.")
                    if !confirmation.notStoppedTitles.isEmpty {
                        exclusions
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, 340))
            HStack(spacing: TaskScreenStyle.Dialog.actionsGap) {
                Spacer(minLength: 0)
                Button("Keep running") { dismiss() }
                    .focused($keepRunningFocused)
                    .keyboardShortcut(.cancelAction)
                Button("Stop task", role: .destructive) {
                    onConfirm()
                    dismiss()
                }
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
        .onAppear { keepRunningFocused = true }
    }

    private var exclusions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Won't be stopped by this").fontWeight(.semibold)
            Text("Started in earlier turns and running when the task list was last read:")
            ForEach(Array(confirmation.notStoppedTitles.enumerated()), id: \.offset) { _, title in
                bullet(title)
            }
            Text("From the task list, not from the engine's cancel result. May be out of date.")
                .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
        }
        .lineSpacing(TaskScreenStyle.lineSpacing(.init(size: 13, lineHeight: 19)))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(TaskScreenStyle.Colors.surfaceSunken.color, in: RoundedRectangle(cornerRadius: TaskScreenStyle.Scale.radiusSmall))
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").accessibilityHidden(true)
            Text(text).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
#Preview("Stop — light") {
    TaskStopConfirmationView(confirmation: .init(conversationID: "conversation", taskID: "task", notStoppedTitles: [], confirm: {}), onConfirm: {})
        .preferredColorScheme(.light)
}

#Preview("Stop — dark") {
    TaskStopConfirmationView(confirmation: .init(conversationID: "conversation", taskID: "task", notStoppedTitles: [], confirm: {}), onConfirm: {})
        .preferredColorScheme(.dark)
}

#Preview("Earlier turns — light") {
    TaskStopConfirmationView(
        confirmation: .init(conversationID: "conversation", taskID: "task", notStoppedTitles: ["Rebuild the index"], confirm: {}),
        onConfirm: {}
    )
        .preferredColorScheme(.light)
}

#Preview("Earlier turns — dark") {
    TaskStopConfirmationView(
        confirmation: .init(conversationID: "conversation", taskID: "task", notStoppedTitles: ["Rebuild the index"], confirm: {}),
        onConfirm: {}
    )
        .preferredColorScheme(.dark)
}
#endif
