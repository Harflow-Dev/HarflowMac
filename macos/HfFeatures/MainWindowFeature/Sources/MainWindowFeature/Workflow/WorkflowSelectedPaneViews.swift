import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowSelectedScrollRegion

/// The block above a transcript: its natural height up to `WorkflowSelectedPaneSizing.topRegionShare` of the pane, then it
/// scrolls inside, so the self-scrolling transcript below keeps its floor.
struct WorkflowSelectedScrollRegion<Content: View>: View {
    let paneHeight: CGFloat
    /// Fixed chrome around the region and the transcript (head, picker, composer), kept out of the transcript's floor.
    var reserved: CGFloat = 0
    /// The natural height of a caller approval awaiting a decision, which outranks this region (0 when none).
    var approvalDemand: CGFloat = 0
    @ViewBuilder let content: () -> Content
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { naturalHeight = $0 }
                .background(ScrollChrome())
        }
        .frame(height: WorkflowSelectedPaneSizing.topRegionHeight(natural: naturalHeight, paneHeight: paneHeight, reserved: reserved,
                                                                            approvalDemand: approvalDemand))
    }
}

// MARK: - WorkflowSelectedHead

/// The pane head: the node title with its status badge, or the faint "On demand" caption, then Close.
struct WorkflowSelectedHead<VM: WorkflowViewModel>: View {
    var viewModel: VM

    var body: some View {
        let state = viewModel.runSidebar
        HStack(spacing: HfRadius.Metrics.spacing8) {
            Text(state.title).font(.hf(.body, weight: .semibold)).lineLimit(1)
            switch state.header.kind {
            case .worker:
                if let id = state.node?["id"]?.stringValue {
                    let status = state.header.badgeStatus(canvasStatus: viewModel.nodeStatus(id))
                    StatusBadge(status: .other(status), presentationOverride: WorkflowNodeStatusPresentation.presentation(status: status))
                        .accessibilityIdentifier("workflow-selected-status")
                }
            case .onDemand:
                if let caption = state.header.caption {
                    Text(caption)
.font(.hf(.caption))
.foregroundStyle(Color.tertiaryText)
                        .accessibilityIdentifier("workflow-selected-on-demand")
                }
            case .orchestrator:
                EmptyView()
            }
            Spacer(minLength: HfRadius.Metrics.zero)
            Button("Close", systemImage: "xmark") { viewModel.selectedNodeID = nil }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Show workflow summary")
        }
        .padding(HfRadius.Metrics.spacing12)
    }
}

// MARK: - WorkflowOnDemandCallList

/// An on-demand node's calls as selectable rows, newest first. Five rows show whole; more scroll.
struct WorkflowOnDemandCallList: View {
    var naturalHeight = false
    let rows: [WorkflowOnDemandCallRow]
    let selectedID: String?
    let onSelect: (String) -> Void
    let onOpenTask: (String) -> Void

    var body: some View {
        if !naturalHeight, rows.count > WorkflowSelectedPaneSizing.visibleCallRows {
            ScrollView { list }
                .frame(height: WorkflowSelectedPaneSizing.callListHeight(rowCount: rows.count))
        } else {
            list
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.zero) {
            ForEach(rows) { row in
                WorkflowOnDemandCallRowView(row: row, isSelected: row.id == selectedID,
                                            onSelect: { onSelect(row.id) }, onOpenTask: onOpenTask)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-on-demand-calls")
    }
}

// MARK: - WorkflowOnDemandCallRowView

/// One call row. A running row owns its one-second clock, so the sidebar presentation stays quiet between ticks.
struct WorkflowOnDemandCallRowView: View {
    @Environment(\.hfMotionPaused) private var motionPaused
    let row: WorkflowOnDemandCallRow
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpenTask: (String) -> Void

    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            Button(action: onSelect) {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    let presentation = StatusBadge.presentation(for: row.indicatorStatus)
                    StatusIndicatorView(presentation.indicator, tint: presentation.tint.foreground)
                    summary
                    Spacer(minLength: HfRadius.Metrics.zero)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            if let taskID = row.taskID {
                Button("Open task") { onOpenTask(taskID) }.buttonStyle(QuietButtonStyle()).font(.hf(.caption))
            }
        }
        .padding(.horizontal, HfRadius.Metrics.spacing8)
        .frame(height: WorkflowSelectedPaneSizing.callRowHeight)
        .background(isSelected ? TaskScreenStyle.Colors.surfaceActive.color : Color.clear, in: RoundedRectangle(cornerRadius: HfRadius.row))
    }

    @ViewBuilder private var summary: some View {
        if row.isRunning, row.startedAt != nil {
            TimelineView(.hfSecond(paused: motionPaused)) { timeline in text(row.summary(now: timeline.date)) }
        } else {
            text(row.summary(now: .now))
        }
    }

    private func text(_ value: String) -> some View {
        Text(value).font(.hf(.secondary, weight: isSelected ? .semibold : .regular)).monospacedDigit().lineLimit(1)
    }
}

// MARK: - WorkflowCallDetailsView

/// The call's assignment, reason and result, for a call with no transcript to carry them.
struct WorkflowCallDetailsView: View {
    let details: WorkflowCallDetails
    var naturalHeight = false

    var body: some View {
        Group {
            if naturalHeight { content } else { ScrollView { content.background(ScrollChrome()) } }
        }.accessibilityIdentifier("workflow-call-details")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            if !details.assignment.isEmpty { Text(details.assignment).font(.hf(.body, weight: .semibold)) }
            Text(details.origin).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            if !details.reason.isEmpty { Text(details.reason).font(.hf(.body)) }
            if !details.result.isEmpty { ReadingMarkdownView(text: details.result) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HfRadius.Metrics.spacing16)
    }
}

#if DEBUG
#Preview("On-demand call list light") {
    WorkflowOnDemandCallList(rows: WorkflowOnDemandPreview.callRows(), selectedID: "specialist-2", onSelect: { _ in }, onOpenTask: { _ in })
        .padding()
.frame(width: HfRadius.Metrics.workflowRunActivityPanelIdealWidth)
.preferredColorScheme(.light)
}

#Preview("On-demand call list dark") {
    WorkflowOnDemandCallList(rows: WorkflowOnDemandPreview.callRows(), selectedID: "specialist-2", onSelect: { _ in }, onOpenTask: { _ in })
        .padding()
.frame(width: HfRadius.Metrics.workflowRunActivityPanelIdealWidth)
.preferredColorScheme(.dark)
}
#endif
