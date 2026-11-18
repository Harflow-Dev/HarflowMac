import SwiftUI

// MARK: - TaskBuilderColumnSizing

/// How the builder column's height is shared between its top region (pinned title rows plus one scroll region) and the
/// activity column (feed and composer). Pure so the split is testable without a window.
struct TaskBuilderColumnSizing: Equatable {
    let top: CGFloat
    let column: CGFloat

    /// The top region takes its natural height, but never less than its minimum, never more than half the total
    /// (tall content scrolls inside the top region, so the conversation keeps at least half) and never so much that the
    /// column drops below its own minimum. When the minimums alone exceed the total, the top keeps its minimum and the
    /// column gets the rest: the top region's scroll region has already shrunk to its floor, so only below that absolute
    /// minimum does the column overflow. Non-finite or negative inputs count as zero.
    static func resolve(total: CGFloat, topNatural: CGFloat, topMinimum: CGFloat, columnMinimum: CGFloat) -> Self {
        let total = clean(total), natural = clean(topNatural), minimum = clean(topMinimum), columnMinimum = clean(columnMinimum)
        let upper = max(minimum, min(total / 2, total - columnMinimum))
        let top = min(max(natural, minimum), upper)
        return Self(top: top, column: max(0, total - top))
    }

    private static func clean(_ value: CGFloat) -> CGFloat { value.isFinite ? max(0, value) : 0 }
}

// MARK: - TaskBuilderColumnLayout

/// Two subviews, the top region and the column, stacked with `TaskBuilderColumnSizing`. Only the builder mount uses
/// it: a plain `VStack` gives the less flexible header half the height and leaves the feed none at the minimum window.
struct TaskBuilderColumnLayout: Layout {
    private struct Measurement {
        let topNatural: CGFloat
        let topMinimum: CGFloat
        let columnNatural: CGFloat
        let columnMinimum: CGFloat
    }

    private func measure(_ subviews: Subviews, width: CGFloat?) -> Measurement {
        Measurement(
            topNatural: subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height,
            topMinimum: subviews[0].sizeThatFits(ProposedViewSize(width: width, height: 0)).height,
            columnNatural: subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height,
            columnMinimum: subviews[1].sizeThatFits(ProposedViewSize(width: width, height: 0)).height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let width = proposal.width ?? subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        let measured = measure(subviews, width: width)
        guard let proposed = proposal.height else {
            return CGSize(width: width, height: measured.topNatural + measured.columnNatural)
        }
        if !proposed.isFinite { return CGSize(width: width, height: proposed) }
        return CGSize(width: width, height: max(proposed, measured.topMinimum + measured.columnMinimum))
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard subviews.count == 2 else { return }
        let width = bounds.width
        let measured = measure(subviews, width: width)
        let sizing = TaskBuilderColumnSizing.resolve(
            total: bounds.height, topNatural: measured.topNatural, topMinimum: measured.topMinimum,
            columnMinimum: measured.columnMinimum)
        let topProposal = ProposedViewSize(width: width, height: sizing.top)
        let topHeight = subviews[0].sizeThatFits(topProposal).height
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: topProposal)
        subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + topHeight), anchor: .topLeading,
                          proposal: ProposedViewSize(width: width, height: max(0, bounds.height - topHeight)))
    }
}

#if DEBUG
#Preview("Builder column layout") {
    TaskBuilderColumnLayout {
        Text("Header").frame(maxWidth: .infinity, minHeight: 130).background(.quaternary)
        Text("Column").frame(maxWidth: .infinity, maxHeight: .infinity).background(.tertiary)
    }
    .frame(width: 460, height: 433)
}
#endif
