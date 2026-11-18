import HfUI
import MonitorCore
import SwiftUI

// MARK: - ParallelColumnsContent

/// Shared horizontal residency surface for the group screen and embedded workflow activity.
struct ParallelColumnsContent: View {
    let columns: [ParallelColumnModel]
    let availableSize: CGSize
    var horizontalPosition: ParallelViewportPosition?
    var explicitNavigationID: String?
    let stateForColumn: (String) -> ParallelColumnUIState
    let onViewport: (CGFloat, CGFloat) -> Void
    @State var residencyHandoffs = ParallelResidencyHandoffStore()

    /// A row's columns share one chrome; the last column's decides the row's trailing separator.
    private var chrome: ParallelColumnChrome { columns.last?.chrome ?? .lane }

    private var columnWidth: CGFloat {
        ParallelLayout.columnWidth(memberCount: columns.count, availableWidth: availableSize.width, chrome: chrome)
    }

    var body: some View {
        LazyHStack(alignment: .top, spacing: HfRadius.Metrics.zero) {
            ForEach(columns) { column in
                // Placeholder motion must not create activity inventory or retained membership.
                ParallelColumnCell(model: column,
                                   state: column.isResident ? stateForColumn(column.id) : nil,
                                   residencyState: residencyHandoffs.state(for: column.id),
                                   size: CGSize(width: columnWidth, height: max(0, availableSize.height)),
                                   isLast: column.id == columns.last?.id)
                    .equatable()
                    .id(column.id)
            }
        }
        .onChange(of: columns.map(\.id), initial: true) { _, ids in residencyHandoffs.retain(ids: Set(ids)) }
        .background(ParallelScrollObserver(axis: .horizontal, columnIDs: columns.map(\.id),
                                           columnStride: columnWidth + ParallelLayout.dividerWidth,
                                           documentTrim: ParallelLayout.trailingTrim(chrome: chrome),
                                           horizontalPosition: horizontalPosition, explicitNavigationID: explicitNavigationID) { offset, _, viewport in
            onViewport(offset, viewport)
        })
    }
}

// MARK: - ParallelLaneSurface

/// The surface of every Parallel column, lane or inspector: HarflowDesign v2's `.hd-lane` and `.hd-pane` share a square,
/// full-bleed `--bg` fill with no status strip, rounded surround or border of its own (a lane's separator is drawn by the
/// cell, never after the last). Status shows only as the `TaskStatusLabel` badge in the column's header. Presentation
/// only — the cell's equality, the resident placeholder, the stable IDs, arrival, the viewport observer and the column
/// stride are owned by their own contracts.
struct ParallelLaneSurface<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content().background(TaskScreenStyle.Colors.pageBackground.color)
    }
}

// MARK: - ParallelLaneSeparator

/// The separator after a lane: a 1 pt `--border` rectangle for lanes (`gap: 1px` on `--border` in the
/// design), the system divider for the inspector.
struct ParallelLaneSeparator: View {
    let chrome: ParallelColumnChrome

    /// A horizontal 1 pt `--border` rule.
    static var hairline: some View {
        Rectangle().fill(TaskScreenStyle.Colors.border.color).frame(height: ParallelLayout.dividerWidth).accessibilityHidden(true)
    }

    var body: some View {
        switch chrome {
        case .lane:
            Rectangle().fill(TaskScreenStyle.Colors.border.color).frame(width: ParallelLayout.dividerWidth)
        case .inspector:
            Divider().frame(width: ParallelLayout.dividerWidth)
        }
    }
}

// MARK: - ParallelColumnCell

/// A neighboring column's event update cannot rebuild this column's unchanged activity view.
struct ParallelColumnCell: View, @MainActor Equatable {
    let model: ParallelColumnModel
    let state: ParallelColumnUIState?
    var residencyState: SkeletonContentState?
    let size: CGSize
    /// The last column of its row: a `.lane` then draws no separator after it. The previous last cell flips when a
    /// member joins, so this takes part in equality.
    var isLast = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model.renderValue == rhs.model.renderValue && lhs.state === rhs.state && lhs.residencyState === rhs.residencyState
            && lhs.size == rhs.size && lhs.isLast == rhs.isLast
    }

    var body: some View {
        HStack(spacing: HfRadius.Metrics.zero) {
            ParallelLaneSurface {
                content
            }
            .frame(width: size.width, height: size.height)
            if !(isLast && model.chrome == .lane) { ParallelLaneSeparator(chrome: model.chrome) }
        }
    }

    @ViewBuilder
    private var content: some View {
        SkeletonContent(isLoading: !model.isResident, state: residencyState) {
            residentPlaceholder
        } content: {
            // Eviction must unmount the feed immediately, independently of the visual handoff.
            if model.isResident, let state {
                ParallelColumnView(model: model, state: state)
                    .onAppear(perform: model.onDidPresent)
            }
        }
        .modifier(PanelArrival(animate: model.animatesArrival))
    }

    @ViewBuilder
    private var residentPlaceholder: some View {
        if model.chrome == .lane {
            // The same one-row head as the mounted lane (without its menu), so a lane does not jump when it becomes resident.
            VStack(alignment: .leading, spacing: HfRadius.Metrics.zero) {
                ParallelLaneHead(title: model.title, caption: model.laneCaption, task: model.task, status: model.laneStatus)
                    .padding(.horizontal, HfRadius.Metrics.spacing16)
                    .padding(.vertical, HfRadius.Metrics.spacing12)
                ParallelLaneSeparator.hairline
                SkeletonRows(count: 4, showsBadge: false)
                    .padding(.top, TaskScreenStyle.Lane.paddingTop)
                    .padding(.horizontal, TaskScreenStyle.Lane.paddingHorizontal)
                Spacer(minLength: HfRadius.Metrics.zero)
            }
            .accessibilityIdentifier("parallel-column-placeholder")
        } else {
            inspectorPlaceholder
        }
    }

    private var inspectorPlaceholder: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
            HStack(alignment: .top, spacing: HfRadius.Metrics.spacing8) {
                StatusIcon(status: model.task.status)
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                    Text(model.title).font(.hf(.headline, weight: .semibold)).lineLimit(2)
                    HStack(spacing: HfRadius.Metrics.spacing6) {
                        BackendDot(backend: model.task.backend)
                        Text(model.subtitle).font(.hf(.secondary)).monospacedDigit().foregroundStyle(Color.secondaryText).lineLimit(1)
                    }
                }
                Spacer(minLength: HfRadius.Metrics.spacing8)
                TaskStatusLabel(task: model.task).fixedSize()
            }
            Divider()
            SkeletonRows(count: 4, showsBadge: false)
            Spacer(minLength: HfRadius.Metrics.zero)
        }
        .padding(HfRadius.Metrics.spacing16)
        .accessibilityIdentifier("parallel-column-placeholder")
    }
}

#if DEBUG
/// One inspector lane's flush boundary: full-bleed page background and the lane's own
/// internal header/skeleton content — no invented data.
@ViewBuilder
@MainActor
private func parallelLaneSurfacePreview() -> some View {
    let task = TaskInfo(.object([
        "task_id": .string("lane-surface-preview"),
        "backend": .string("codex"),
        "status": .string("running"),
        "repo_path": .string("/tmp")
    ]))!
    ParallelLaneSurface {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
            HStack(spacing: HfRadius.Metrics.spacing8) {
                StatusIcon(status: task.status)
                Text("Lane").font(.hf(.headline, weight: .semibold))
                Spacer(minLength: HfRadius.Metrics.spacing8)
                TaskStatusLabel(task: task).fixedSize()
            }
            Divider()
            SkeletonRows(count: 4, showsBadge: false)
            Spacer(minLength: HfRadius.Metrics.zero)
        }
        .padding(HfRadius.Metrics.spacing16)
    }
    .frame(width: HfRadius.Metrics.toolRowPreviewWidth, height: HfRadius.Metrics.sidebarPreviewHeight)
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
                               availableSize: CGSize(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.sidebarPreviewHeight),
                               stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in })
    }
    .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("Parallel columns - dark") {
    ScrollView(.horizontal) {
        ParallelColumnsContent(columns: ParallelViewModelMock().columns,
                               availableSize: CGSize(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.sidebarPreviewHeight),
                               stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in })
    }
    .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.sidebarPreviewHeight)
    .preferredColorScheme(.dark)
}
#endif

// MARK: - ParallelResidencyHandoffStore

/// Only placeholder motion is retained for rendered descriptors that have never been resident.
/// Activity state remains owned by the VM and is acquired only for resident columns.
@MainActor @Observable final class ParallelResidencyHandoffStore {
    @ObservationIgnored private var states: [String: SkeletonContentState]

    init(states: [String: SkeletonContentState] = [:]) { self.states = states }

    func state(for id: String) -> SkeletonContentState {
        if let state = states[id] { return state }
        let state = SkeletonContentState()
        states[id] = state
        return state
    }

    func retain(ids: Set<String>) { states = states.filter { ids.contains($0.key) } }
}
