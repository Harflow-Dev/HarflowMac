import CoreGraphics
@testable import MainWindowFeature
import Testing

struct StatisticsChartHoverTests {
    /// Plot geometry with whole-number column widths so boundary values are exact.
    struct Layout: Sendable, CustomTestStringConvertible {
        var count: Int
        var gap: CGFloat
        var columnWidth: CGFloat

        var width: CGFloat { CGFloat(count) * columnWidth + CGFloat(count - 1) * gap }
        var pitch: CGFloat { columnWidth + gap }
        var columns: StatisticsChartHover.Columns {
            .init(plotSize: CGSize(width: width, height: 180), count: count, gap: gap)
        }

        var testDescription: String { "\(count) days, gap \(gap)" }
    }

    static let layouts = [
        Layout(count: 7, gap: 16, columnWidth: 80),
        Layout(count: 30, gap: 4, columnWidth: 20),
        Layout(count: 90, gap: 2, columnWidth: 6)
    ]

    private let sevenDays = Layout(count: 7, gap: 16, columnWidth: 80)
    private let cardSize = CGSize(width: 220, height: 60)

    // MARK: - columnIndex

    @Test(arguments: layouts)
    func givenColumnCentres_whenIndexResolved_thenEachColumnIsReturned(layout: Layout) {
        // given
        let columns = layout.columns

        // when
        let indices = (0 ..< layout.count).map {
            StatisticsChartHover.columnIndex(x: CGFloat($0) * layout.pitch + layout.columnWidth / 2, columns: columns)
        }

        // then
        #expect(indices == (0 ..< layout.count).map { Optional($0) })
    }

    @Test(arguments: layouts)
    func givenGapMidpoint_whenIndexResolved_thenPointBelongsToNearerColumn(layout: Layout) {
        // given
        let columns = layout.columns
        let midpoint = layout.columnWidth + layout.gap / 2

        // when
        let before = StatisticsChartHover.columnIndex(x: midpoint - 0.5, columns: columns)
        let exact = StatisticsChartHover.columnIndex(x: midpoint, columns: columns)
        let after = StatisticsChartHover.columnIndex(x: midpoint + 0.5, columns: columns)

        // then
        #expect(before == 0)
        #expect(exact == 1)
        #expect(after == 1)
    }

    @Test(arguments: layouts)
    func givenPlotEdges_whenIndexResolved_thenFirstAndLastColumnsAreReturned(layout: Layout) {
        // given
        let columns = layout.columns

        // when
        let leading = StatisticsChartHover.columnIndex(x: 0, columns: columns)
        let trailing = StatisticsChartHover.columnIndex(x: layout.width, columns: columns)

        // then
        #expect(leading == 0)
        #expect(trailing == layout.count - 1)
    }

    @Test(arguments: layouts)
    func givenOutOfRangeX_whenIndexResolved_thenIndexIsClamped(layout: Layout) {
        // given
        let columns = layout.columns

        // when
        let negative = StatisticsChartHover.columnIndex(x: -500, columns: columns)
        let beyond = StatisticsChartHover.columnIndex(x: layout.width + 500, columns: columns)

        // then
        #expect(negative == 0)
        #expect(beyond == layout.count - 1)
    }

    @Test func givenDegenerateInput_whenIndexResolved_thenNoColumnIsReturned() {
        // given
        let empty = StatisticsChartHover.Columns(plotSize: CGSize(width: 100, height: 180), count: 0, gap: 4)
        let zeroWidth = StatisticsChartHover.Columns(plotSize: CGSize(width: 0, height: 180), count: 7, gap: 0)

        // when
        let noBars = StatisticsChartHover.columnIndex(x: 10, columns: empty)
        let noWidth = StatisticsChartHover.columnIndex(x: 10, columns: zeroWidth)
        let notANumber = StatisticsChartHover.columnIndex(x: .nan, columns: sevenDays.columns)

        // then
        #expect(noBars == nil)
        #expect(noWidth == nil)
        #expect(notANumber == nil)
    }

    // MARK: - cardOrigin

    @Test func givenColumnInMiddle_whenCardPlaced_thenItIsCentredAndEightPointsAboveBarTop() {
        // given
        let columns = sevenDays.columns

        // when
        let origin = StatisticsChartHover.cardOrigin(
            columns: columns, index: 3, stackedFraction: 0.5, cardSize: cardSize, topInset: 70
        )

        // then
        #expect(origin.x == CGFloat(3 * 96 + 40 - 110))
        #expect(origin.y + cardSize.height + 8 == CGFloat(90))
    }

    @Test func givenFirstAndLastColumns_whenCardPlaced_thenItIsClampedInsidePlot() {
        // given
        let columns = sevenDays.columns

        // when
        let first = StatisticsChartHover.cardOrigin(columns: columns, index: 0, stackedFraction: 0.5, cardSize: cardSize, topInset: 70)
        let last = StatisticsChartHover.cardOrigin(columns: columns, index: 6, stackedFraction: 0.5, cardSize: cardSize, topInset: 70)

        // then
        #expect(first.x == 0)
        #expect(last.x == columns.plotSize.width - cardSize.width)
    }

    @Test func givenCardWiderThanPlot_whenCardPlaced_thenItStartsAtPlotLeadingEdge() {
        // given
        let columns = StatisticsChartHover.Columns(plotSize: CGSize(width: 150, height: 180), count: 3, gap: 0)

        // when
        let origin = StatisticsChartHover.cardOrigin(columns: columns, index: 2, stackedFraction: 0.5, cardSize: cardSize, topInset: 70)

        // then
        #expect(origin.x == 0)
    }

    @Test func givenFullHeightBar_whenCardPlaced_thenTopIsClampedEightPointsInsideChartCard() {
        // given
        let columns = sevenDays.columns

        // when
        let origin = StatisticsChartHover.cardOrigin(columns: columns, index: 3, stackedFraction: 1, cardSize: cardSize, topInset: 70)
        let flush = StatisticsChartHover.cardOrigin(columns: columns, index: 3, stackedFraction: 1, cardSize: cardSize, topInset: 0)

        // then
        #expect(origin.y == CGFloat(8 - 70))
        #expect(flush.y == CGFloat(8))
    }

    @Test func givenEmptyOrOutOfRangeFraction_whenCardPlaced_thenFractionIsClamped() {
        // given
        let columns = sevenDays.columns

        // when
        let empty = StatisticsChartHover.cardOrigin(columns: columns, index: 3, stackedFraction: 0, cardSize: cardSize, topInset: 70)
        let negative = StatisticsChartHover.cardOrigin(columns: columns, index: 3, stackedFraction: -1, cardSize: cardSize, topInset: 70)
        let over = StatisticsChartHover.cardOrigin(columns: columns, index: 3, stackedFraction: 2, cardSize: cardSize, topInset: 70)

        // then
        #expect(empty.y == CGFloat(180 - 8) - cardSize.height)
        #expect(negative == empty)
        #expect(over.y == CGFloat(8 - 70))
    }

    // MARK: - clamped

    @Test func givenCardInsideVisibleRect_whenClamped_thenOriginIsUnchanged() {
        // given
        let origin = CGPoint(x: 218, y: 120)
        let visible = CGRect(x: 0, y: 0, width: 656, height: 400)

        // when
        let result = StatisticsChartHover.clamped(origin: origin, cardSize: cardSize, to: visible)

        // then
        #expect(result == origin)
    }

    @Test func givenVisibleRectExcludingTop_whenClamped_thenCardMovesDownToVisibleTop() {
        // given
        let origin = CGPoint(x: 218, y: 22)
        let visible = CGRect(x: 0, y: 100, width: 656, height: 400)

        // when
        let result = StatisticsChartHover.clamped(origin: origin, cardSize: cardSize, to: visible)

        // then
        #expect(result == CGPoint(x: 218, y: 100))
    }

    @Test func givenVisibleRectExcludingRightSide_whenClamped_thenCardMovesLeftInsideVisibleEdge() {
        // given
        let origin = CGPoint(x: 436, y: 22)
        let visible = CGRect(x: 0, y: 0, width: 300, height: 400)

        // when
        let result = StatisticsChartHover.clamped(origin: origin, cardSize: cardSize, to: visible)

        // then
        #expect(result == CGPoint(x: 80, y: 22))
    }

    @Test func givenVisibleRectExcludingLeftSideAndBottom_whenClamped_thenCardMovesInsideBothEdges() {
        // given
        let origin = CGPoint(x: 10, y: 500)
        let visible = CGRect(x: 100, y: 0, width: 400, height: 400)

        // when
        let result = StatisticsChartHover.clamped(origin: origin, cardSize: cardSize, to: visible)

        // then
        #expect(result == CGPoint(x: 100, y: 340))
    }

    @Test func givenVisibleRectSmallerThanCard_whenClamped_thenTopLeadingCornerStaysVisible() {
        // given
        let origin = CGPoint(x: 400, y: 300)
        let visible = CGRect(x: 50, y: 40, width: 100, height: 30)

        // when
        let result = StatisticsChartHover.clamped(origin: origin, cardSize: cardSize, to: visible)

        // then
        #expect(result == CGPoint(x: 50, y: 40))
    }
}
