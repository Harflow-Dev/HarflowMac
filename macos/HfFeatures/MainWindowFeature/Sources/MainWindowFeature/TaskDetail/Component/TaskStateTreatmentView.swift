import SwiftUI

// MARK: - TaskStateTreatmentView

/// Approved M05 uncertainty treatments (HarflowDesign 17739e4, m05-proposal.js).
struct TaskStateTreatmentView: View {
    let model: TaskStateTreatment
    var onStop: () -> Void = {}
    var onRefresh: () -> Void = {}
    var onCopyResumeCommand: () -> Void = {}
    var onOpenEvents: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: TaskScreenStyle.Banner.gap) {
                Image(systemName: isInformationNotice ? "clock" : "exclamationmark.triangle")
                    .font(TaskScreenStyle.sans(size: 14))
                    .frame(width: 14, height: 14)
                    .foregroundStyle(isInformationNotice ? TaskScreenStyle.Colors.textSecondary.color : TaskScreenStyle.Colors.warning.color)
                    .padding(.top, model.isLeadingNotice ? 0 : TaskScreenStyle.Banner.iconTopInset)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                    Text(message).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    if !model.isLeadingNotice {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) { actions }
                            VStack(alignment: .leading, spacing: 8) { actions }
                        }
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if model.kind == .statusUnavailable {
                    Button("Retry read", action: onRefresh)
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("task-state-refresh")
                }
            }
            .font(TaskScreenStyle.sans(size: textSpec.size))
            .lineSpacing(TaskScreenStyle.lineSpacing(textSpec))
            .foregroundStyle(TaskScreenStyle.Colors.text.color)
            .padding(.horizontal, model.isLeadingNotice ? TaskScreenStyle.Notice.paddingHorizontal : TaskScreenStyle.Banner.paddingHorizontal)
            .padding(.vertical, model.isLeadingNotice ? TaskScreenStyle.Notice.paddingVertical : TaskScreenStyle.Banner.paddingVertical)
            .background(noticeFill, in: RoundedRectangle(cornerRadius: TaskScreenStyle.Banner.cornerRadius))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(model.isLeadingNotice ? "Status notice" : "Warning")
            .accessibilityIdentifier("task-state-" + model.kind.rawValue)
            if model.kind == .unknownFailed {
                Text("Continue needs an observed exit and fully read output, which this run does not have.")
                    .font(TaskScreenStyle.sans(size: 12))
                    .lineSpacing(TaskScreenStyle.lineSpacing(.init(size: 12, lineHeight: 17)))
                    .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var isInformationNotice: Bool { model.kind == .stopping || model.kind == .settling }

    private var noticeFill: Color {
        isInformationNotice ? TaskScreenStyle.Colors.surfaceSunken.color : TaskScreenStyle.Colors.warningSubtle.color
    }

    private var textSpec: TaskScreenStyle.TextSpec { model.isLeadingNotice ? TaskScreenStyle.Notice.text : TaskScreenStyle.Banner.text }

    private var title: String {
        switch model.kind {
        case .statusUnavailable: "Current status unavailable"
        case .settling: "Settling"
        case .stopping: "Stop requested"
        case .ownerLost: "The process watching this run is gone"
        case .unverified: "Harflow can't confirm this run"
        case .reconstructed: "Reconstructed outcome"
        case .unknownFailed: "Outcome inferred, not observed"
        }
    }

    private var message: String {
        switch model.kind {
        case .statusUnavailable: "The engine did not answer. Everything below was read earlier and may be out of date."
        case .settling: "The run finished. Its last events and stored changes may still arrive."
        case .stopping: "This run has not exited yet. The status changes when Harflow records the outcome."
        case .ownerLost:
            "Captured output has stopped and no later summary is promised. The run itself may still be working. "
                + "Check its changes or stop it before starting a replacement."
        case .unverified:
            "It can't tell whether the process watching this run is alive. Output may or may not still be captured, "
                + "and a later summary is unknown. Check status again before starting a replacement."
        case .reconstructed: "Harflow did not see this process exit. Done comes from the run's own closing output."
        case .unknownFailed:
            "Harflow never saw this process exit and found no result in its output, so it reports failed. "
                + "Nothing it had already written was undone."
        }
    }

    @ViewBuilder private var actions: some View {
        switch model.kind {
        case .ownerLost:
            stop
            refresh
        case .unverified:
            refresh
            stop
        case .unknownFailed:
            Button("Continue in a new session", systemImage: "arrow.clockwise", action: {})
                .disabled(true)
.buttonStyle(.bordered)
                .accessibilityIdentifier("task-state-continue")
            if model.showsCopyResumeCommand {
                Button("Copy resume command", systemImage: "doc.on.doc", action: onCopyResumeCommand)
                    .buttonStyle(.borderless)
.accessibilityIdentifier("task-state-copy-resume")
            }
            Button("Open Events", action: onOpenEvents)
.buttonStyle(.borderless)
                .accessibilityIdentifier("task-state-open-events")
        case .statusUnavailable, .reconstructed, .stopping, .settling: EmptyView()
        }
    }

    private var stop: some View {
        Button("Stop task", systemImage: "stop", role: .destructive, action: onStop)
            .buttonStyle(.bordered)
.disabled(model.isStopDisabled)
            .accessibilityIdentifier("task-state-stop")
    }

    @ViewBuilder private var refresh: some View {
        if model.kind == .unverified {
            Button("Refresh", action: onRefresh)
.buttonStyle(.bordered)
                .accessibilityIdentifier("task-state-refresh")
        } else {
            Button("Refresh", action: onRefresh)
.buttonStyle(.borderless)
                .accessibilityIdentifier("task-state-refresh")
        }
    }
}

#if DEBUG
#Preview("Unverified") {
    TaskStateTreatmentView(model: .init(taskID: "preview", kind: .unverified))
        .padding()
.frame(width: 420)
}

#Preview("Inferred outcome") {
    TaskStateTreatmentView(model: .init(taskID: "preview", kind: .unknownFailed, showsCopyResumeCommand: true))
        .padding()
.frame(width: 420)
.preferredColorScheme(.dark)
}
#endif
