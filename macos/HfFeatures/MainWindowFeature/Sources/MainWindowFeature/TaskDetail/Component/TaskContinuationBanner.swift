import HfUI
import SwiftUI

// MARK: - TaskContinuationBanner

/// Approved Continue treatment; no diagnostic is inferred from captured output.
struct TaskContinuationBanner: View {
    let model: TaskContinuationPresentation
    var showsCopyResumeCommand = false
    var onContinue: (String) -> Void = { _ in }
    var onCheck: (String, UUID) -> Void = { _, _ in }
    var onNewTask: () -> Void = {}
    var onCopyResumeCommand: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: TaskScreenStyle.Banner.gap) {
                Image(systemName: model.phase == .accepted ? "clock" : "exclamationmark.triangle")
                    .font(TaskScreenStyle.sans(size: 14))
.frame(width: 14, height: 14)
.accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(model.title).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                    if !model.body.isEmpty { Text(model.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                    if let message = model.message {
                        Text(message)
.font(.hf(.caption, design: .monospaced))
                            .fixedSize(horizontal: false, vertical: true)
.textSelection(.enabled)
.padding(.top, 6)
                    }
                    if model.phase != .accepted {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { actions }
                            VStack(alignment: .leading, spacing: 8) { actions }
                        }.padding(.top, 8)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(TaskScreenStyle.sans(size: textSpec.size))
            .lineSpacing(TaskScreenStyle.lineSpacing(textSpec))
            .foregroundStyle(TaskScreenStyle.Colors.text.color)
            .padding(.horizontal, model.phase == .accepted ? TaskScreenStyle.Notice.paddingHorizontal : TaskScreenStyle.Banner.paddingHorizontal)
            .padding(.vertical, model.phase == .accepted ? TaskScreenStyle.Notice.paddingVertical : TaskScreenStyle.Banner.paddingVertical)
            .background(fillColor,
                        in: RoundedRectangle(cornerRadius: TaskScreenStyle.Banner.cornerRadius))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("task-continuation-" + phaseIdentifier)
            if model.phase == .unknown {
                caption("Reads recorded successors only. A task still waiting for resources does not appear until it starts.")
            } else if model.phase == .eligible, model.status == .failed {
                caption("A new session starts from the stored request, summary and outcome. It can repeat work already done. Files are not rolled back.")
            }
        }
    }

    private var textSpec: TaskScreenStyle.TextSpec {
        model.phase == .accepted ? TaskScreenStyle.Notice.text : TaskScreenStyle.Banner.text
    }

    private var isDanger: Bool {
        (model.phase == .eligible || model.phase == .starting) && model.status != .cancelled
    }

    private var fillColor: Color {
        if model.phase == .accepted { return TaskScreenStyle.Notice.fill.color }
        return isDanger ? TaskScreenStyle.Banner.danger.background.color : TaskScreenStyle.Banner.warning.background.color
    }

    private var phaseIdentifier: String {
        switch model.phase {
        case .eligible: "eligible"
        case .starting: "starting"
        case .accepted: "accepted"
        case .refused: "refused"
        case .unknown: "unknown"
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
.font(TaskScreenStyle.sans(size: 12))
.lineSpacing(TaskScreenStyle.lineSpacing(.init(size: 12, lineHeight: 17)))
.foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
            .fixedSize(horizontal: false, vertical: true)
.padding(.top, TaskScreenStyle.Scale.space4)
    }

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .eligible, .starting:
            Button(model.phase == .starting ? "Starting…" : "Continue in a new session", systemImage: "arrow.clockwise") {
                onContinue(model.taskID)
            }
.buttonStyle(.bordered)
.disabled(!model.canContinue)
.accessibilityIdentifier("task-state-continue")
            if model.phase != .starting, showsCopyResumeCommand { copyResume }
        case .unknown:
            Button(model.isChecking ? "Checking…" : "Check for a new task") {
                if let attemptID = model.attemptID { onCheck(model.taskID, attemptID) }
            }
.buttonStyle(.bordered)
.disabled(!model.canCheck || model.isChecking)
.accessibilityIdentifier("task-state-check")
        case .refused:
            Button("New task", action: onNewTask).buttonStyle(.bordered).accessibilityIdentifier("task-state-new-task")
            if showsCopyResumeCommand { copyResume }
        case .accepted: EmptyView()
        }
    }

    private var copyResume: some View {
        Button("Copy resume command", systemImage: "doc.on.doc", action: onCopyResumeCommand)
            .buttonStyle(.borderless)
.accessibilityIdentifier("task-state-copy-resume")
    }
}

#if DEBUG
#Preview("Continue refused") {
    TaskContinuationBanner(model: .init(taskID: "preview", phase: .refused, status: .failed,
                                        message: "The engine's reported reason."), showsCopyResumeCommand: true)
        .padding()
.frame(width: 420)
}
#endif
