import HfUI
import SwiftUI

// MARK: - StatisticsViewport

/// The latest visible rect of the statistics scroll view, in the scroll content's coordinate space.
/// A plain reference type: updating it never invalidates SwiftUI; an observer is attached only while a hover is active.
@MainActor
final class StatisticsViewport {
    static let contentSpace = "statisticsScrollContent"
    static let chartCardSpace = "statisticsChartCard"

    private(set) var rect: CGRect?
    var observer: ((CGRect) -> Void)?

    func update(_ rect: CGRect) {
        guard rect != self.rect else { return }
        self.rect = rect
        observer?(rect)
    }
}

// MARK: - StatisticsChartPlot

/// The chart plot with its hover band and floating card. Hover state is local to this view, so pointer movement
/// never re-renders the rest of the statistics screen.
struct StatisticsChartPlot: View {
    let chart: StatisticsChart
    let viewport: StatisticsViewport
    let minimumCardWidth: CGFloat

    @State private var hoverX: CGFloat?
    /// The day labels the pointer position was recorded against. A range or day-shift change (such as a midnight refresh)
    /// invalidates the hover; a filter or measure change keeps hovering the same day with fresh values.
    @State private var hoverBarDates: [String] = []
    @State private var cardSize: CGSize = .zero
    @State private var visibleRect: CGRect?
    @State private var plotFrame: CGRect = .zero
    @State private var topInset: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            let hovered = hoveredIndex(width: geometry.size.width)
            bars(geometry: geometry, hovered: hovered)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(location): hover(at: location.x)
                    case .ended: stopHover()
                    }
                }
                .overlay(alignment: .topLeading) { card(hovered: hovered, plotSize: geometry.size) }
        }
        .frame(height: 180)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(StatisticsViewport.contentSpace)) } action: { plotFrame = $0 }
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(StatisticsViewport.chartCardSpace)).minY } action: { topInset = $0 }
        .onChange(of: chart.bars) { stopHover() }
        .onDisappear { stopHover() }
    }

    private func bars(geometry: GeometryProxy, hovered: Int?) -> some View {
        HStack(alignment: .bottom, spacing: chart.gap) {
            ForEach(chart.bars) { bar in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.accentColor.opacity(0.5)).frame(height: geometry.size.height * max(0, min(1, bar.taskFraction)))
                    Rectangle().fill(Color.accentColor).frame(height: geometry.size.height * max(0, min(1, bar.workflowFraction)))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(bar.accessibilityLabel)
            }
        }
        .frame(height: geometry.size.height)
        .background {
            ZStack(alignment: .topLeading) {
                if let hovered { band(index: hovered, size: geometry.size) }
                VStack(spacing: 0) {
                    Rectangle().fill(Color.cardBorder).frame(height: 1)
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.cardBorder).frame(height: 1)
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.cardBorder).frame(height: 1)
                }.accessibilityHidden(true)
            }
        }
    }

    private func band(index: Int, size: CGSize) -> some View {
        let count = chart.bars.count
        let columnWidth = (size.width - CGFloat(count - 1) * chart.gap) / CGFloat(count)
        return RoundedRectangle(cornerRadius: 4)
            .fill(Color.selectedRow)
            .frame(width: columnWidth + 2, height: size.height)
            .offset(x: CGFloat(index) * (columnWidth + chart.gap) - 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func card(hovered: Int?, plotSize: CGSize) -> some View {
        if let hovered, chart.bars.indices.contains(hovered) {
            let bar = chart.bars[hovered]
            let origin = cardOrigin(bar: bar, index: hovered, plotSize: plotSize)
            StatisticsHoverCard(bar: bar, minimumWidth: minimumCardWidth)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { cardSize = $0 }
                .opacity(cardSize == .zero ? 0 : 1)
                .offset(x: origin.x, y: origin.y)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func cardOrigin(bar: StatisticsBar, index: Int, plotSize: CGSize) -> CGPoint {
        let origin = StatisticsChartHover.cardOrigin(
            columns: columns(width: plotSize.width, height: plotSize.height),
            index: index,
            stackedFraction: bar.workflowFraction + bar.taskFraction,
            cardSize: cardSize,
            topInset: topInset
        )
        guard let visibleRect, cardSize != .zero else { return origin }
        return StatisticsChartHover.clamped(
            origin: origin,
            cardSize: cardSize,
            to: visibleRect.offsetBy(dx: -plotFrame.minX, dy: -plotFrame.minY)
        )
    }

    private func columns(width: CGFloat, height: CGFloat) -> StatisticsChartHover.Columns {
        .init(plotSize: CGSize(width: width, height: height), count: chart.bars.count, gap: chart.gap)
    }

    private func hoveredIndex(width: CGFloat) -> Int? {
        guard let hoverX, hoverBarDates == chart.bars.map(\.hoverDate) else { return nil }
        return StatisticsChartHover.columnIndex(x: hoverX, columns: columns(width: width, height: 0))
    }

    private func hover(at x: CGFloat) {
        if hoverX == nil { startTracking() }
        hoverX = x
        hoverBarDates = chart.bars.map(\.hoverDate)
    }

    private func startTracking() {
        visibleRect = viewport.rect
        let binding = $visibleRect
        viewport.observer = { rect in if binding.wrappedValue != rect { binding.wrappedValue = rect } }
    }

    private func stopHover() {
        viewport.observer = nil
        if hoverX != nil { hoverX = nil }
        if cardSize != .zero { cardSize = .zero }
    }
}

// MARK: - StatisticsHoverCard

/// The floating day summary: date, total, and one row per series, or "No finished work" for an empty day.
private struct StatisticsHoverCard: View {
    let bar: StatisticsBar
    let minimumWidth: CGFloat

    private static let horizontalPadding: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Color.clear.frame(width: minimumWidth - 2 * Self.horizontalPadding, height: 0)
            Text(bar.hoverDate).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            Text(bar.hoverTotal).font(.hf(.headline, weight: .semibold)).foregroundStyle(Color.primaryText)
            if let note = bar.hoverNote {
                Text(note).font(.hf(.caption)).foregroundStyle(Color.tertiaryText)
            }
            if bar.hasFinishedWork {
                row("Workflow runs", value: bar.hoverWorkflow, color: .accentColor)
                row("Tasks", value: bar.hoverTasks, color: .accentColor.opacity(0.5))
            } else {
                Text("No finished work").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            }
        }
        .lineLimit(1)
        .fixedSize()
        .padding(.vertical, 10)
        .padding(.horizontal, Self.horizontalPadding)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.cardBorder))
        .shadow(color: .black.opacity(0.13), radius: 12, y: 8)
    }

    private func row(_ title: String, value: String, color: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(title).foregroundStyle(Color.secondaryText)
            Spacer(minLength: 0)
            Text(value).fontWeight(.semibold).foregroundStyle(Color.primaryText)
        }.font(.hf(.secondary))
    }
}
