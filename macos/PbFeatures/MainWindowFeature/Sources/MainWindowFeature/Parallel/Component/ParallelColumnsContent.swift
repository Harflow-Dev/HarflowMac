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
        LazyHStack(alignment: .top, spacing: 0) {
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
        HStack(spacing: 0) {
            content
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    StatusIcon(status: model.task.status)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.title).font(.pb(.body, weight: .semibold)).lineLimit(2)
                        Text(model.subtitle).font(.pb(.caption)).foregroundStyle(Color.secondaryText).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    TaskStatusLabel(task: model.task).fixedSize()
                }
                Divider()
                SkeletonRows(count: 4, showsBadge: false)
                Spacer(minLength: 0)
            }
            .padding(16)
            .accessibilityIdentifier("parallel-column-placeholder")
        }
    }
}

#if DEBUG
#Preview {
    ScrollView(.horizontal) {
        ParallelColumnsContent(columns: ParallelViewModelMock().columns, availableSize: CGSize(width: 1000, height: 600),
                               stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in })
    }
    .frame(width: 1000, height: 600)
}
#endif
