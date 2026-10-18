import MonitorCore
import PbUI
import SwiftUI

// MARK: - ParallelColumnsContent

/// Shared horizontal residency surface for the group screen and embedded workflow activity.
struct ParallelColumnsContent: View {
    let columns: [ParallelColumnModel]
    let availableSize: CGSize
    let stateForColumn: (String) -> ParallelColumnUIState
    let onViewport: (CGFloat, CGFloat) -> Void

    private var columnWidth: CGFloat {
        ParallelLayout.columnWidth(memberCount: columns.count, availableWidth: availableSize.width)
    }

    var body: some View {
        LazyHStack(alignment: .top, spacing: PbRadius.Metrics.zero) {
            ForEach(columns) { column in
                ParallelColumnCell(model: column,
                                   state: column.isResident ? stateForColumn(column.id) : nil,
                                   size: CGSize(width: columnWidth, height: max(0, availableSize.height)))
                    .equatable()
                    .id(column.id)
            }
        }
        .background(ParallelScrollObserver(axis: .horizontal, columnIDs: columns.map(\.id),
                                           columnStride: columnWidth + ParallelLayout.dividerWidth) { offset, _, viewport in
            onViewport(offset, viewport)
        })
    }
}

// MARK: - ParallelLaneSurface

/// The lane surface (user amendment to SPEC §6.5): a square, full-lane `cardFill` background with
/// an optional 3 pt status strip across its top edge — no rounded pane surround, hairline border
/// or clip, so the lanes stay edge-to-edge as before the redesign. Presentation only — the cell's
/// equality, the resident placeholder, the stable IDs, arrival, the viewport observer and the
/// column stride are all owned by their own unchanged contracts.
struct ParallelLaneSurface<Content: View>: View {
    /// The status-tinted top strip's colour; `nil` (the default) draws no strip — an unknown
    /// status never gets an invented one.
    var statusTint: Color?
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(Color.cardFill)
            .overlay(alignment: .top) {
                if let statusTint {
                    Rectangle()
                        .fill(statusTint)
                        .frame(height: PbRadius.Metrics.parallelLaneStatusStripHeight)
                        .accessibilityHidden(true)
                }
            }
    }
}

// MARK: - ParallelColumnCell

/// A neighboring column's event update cannot rebuild this column's unchanged activity view.
struct ParallelColumnCell: View, @MainActor Equatable {
    let model: ParallelColumnModel
    let state: ParallelColumnUIState?
    let size: CGSize

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model.renderValue == rhs.model.renderValue && lhs.state === rhs.state && lhs.size == rhs.size
    }

    var body: some View {
        HStack(spacing: PbRadius.Metrics.zero) {
            ParallelLaneSurface(statusTint: ParallelLaneTint.color(for: model.task.status)) {
                content
            }
            .frame(width: size.width, height: size.height)
            Divider().frame(width: ParallelLayout.dividerWidth)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isResident, let state {
            ParallelColumnView(model: model, state: state)
                .modifier(PanelArrival(animate: model.animatesArrival))
                .onAppear(perform: model.onDidPresent)
        } else {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
                HStack(alignment: .top, spacing: PbRadius.Metrics.spacing8) {
                    StatusIcon(status: model.task.status)
                    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                        Text(model.title).font(.pb(.headline, weight: .semibold)).lineLimit(2)
                        HStack(spacing: PbRadius.Metrics.spacing6) {
                            BackendDot(backend: model.task.backend)
                            Text(model.subtitle).font(.pb(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText).lineLimit(1)
                        }
                    }
                    Spacer(minLength: PbRadius.Metrics.spacing8)
                    TaskStatusLabel(task: model.task).fixedSize()
                }
                Divider()
                SkeletonRows(count: 4, showsBadge: false)
                Spacer(minLength: PbRadius.Metrics.zero)
            }
            .padding(PbRadius.Metrics.spacing16)
            .accessibilityIdentifier("parallel-column-placeholder")
        }
    }
}

// MARK: - ParallelLaneTint

/// Pure status mapping, independent of the lane's generic content type.
enum ParallelLaneTint {
    static func color(for status: TaskStatus) -> Color? {
        switch status {
        case .running: Color.runningFG
        case .completed: Color.doneGreen
        case .failed, .timedOut: Color.failedRed
        case .cancelled: Color.cancelledGray
        case .other: nil
        }
    }
}

#if DEBUG
/// One lane's flush boundary as the amendment draws it: full-bleed `cardFill`, the truthful
/// status strip, and the lane's own internal header/skeleton content — no invented data.
@ViewBuilder
@MainActor
private func parallelLaneSurfacePreview() -> some View {
    let task = TaskInfo(.object([
        "task_id": .string("lane-surface-preview"),
        "backend": .string("codex"),
        "status": .string("running"),
        "repo_path": .string("/tmp")
    ]))!
    return ParallelLaneSurface(statusTint: ParallelLaneTint.color(for: task.status)) {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
            HStack(spacing: PbRadius.Metrics.spacing8) {
                StatusIcon(status: task.status)
                Text("Lane").font(.pb(.headline, weight: .semibold))
                Spacer(minLength: PbRadius.Metrics.spacing8)
                TaskStatusLabel(task: task).fixedSize()
            }
            Divider()
            SkeletonRows(count: 4, showsBadge: false)
            Spacer(minLength: PbRadius.Metrics.zero)
        }
        .padding(PbRadius.Metrics.spacing16)
    }
    .frame(width: PbRadius.Metrics.toolRowPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
}

#Preview("Parallel lane surface - light") {
    parallelLaneSurfacePreview().preferredColorScheme(.light)
}

#Preview("Parallel lane surface - dark") {
    parallelLaneSurfacePreview().preferredColorScheme(.dark)
}

#Preview("Parallel columns - light") {
    ScrollView(.horizontal) {
        ParallelColumnsContent(columns: ParallelViewModelMock().columns,
                               availableSize: CGSize(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.sidebarPreviewHeight),
                               stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in })
    }
    .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("Parallel columns - dark") {
    ScrollView(.horizontal) {
        ParallelColumnsContent(columns: ParallelViewModelMock().columns,
                               availableSize: CGSize(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.sidebarPreviewHeight),
                               stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in })
    }
    .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.dark)
}
#endif
