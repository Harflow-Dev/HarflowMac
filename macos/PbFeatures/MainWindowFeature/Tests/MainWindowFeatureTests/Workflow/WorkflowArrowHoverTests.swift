import Foundation
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - WorkflowArrowHoverTests

@Suite struct WorkflowArrowHoverTests {
    private func candidate(_ id: String, y: CGFloat) -> WorkflowArrowHover.Candidate {
        let points = [CGPoint(x: 0, y: y), CGPoint(x: 100, y: y)]
        var path = Path()
        path.move(to: points[0])
        path.addLine(to: points[1])
        return WorkflowArrowHover.Candidate(id: id, path: path, points: points)
    }

    @Test func givenOverlappingArrowHitRegions_whenHovering_thenNearestWinsAndTiesAreDeterministic() {
        // given
        let candidates = [candidate("b", y: 4), candidate("a", y: 0)]
        // when / then
        #expect(WorkflowArrowHover.nearest(to: CGPoint(x: 50, y: 3), candidates: candidates) == "b")
        #expect(WorkflowArrowHover.nearest(to: CGPoint(x: 50, y: 2), candidates: candidates) == "a")
        #expect(WorkflowArrowHover.nearest(to: CGPoint(x: 50, y: 40), candidates: candidates) == nil)
    }

    @Test func givenBentPathBoundingBox_whenHoveringAwayFromStroke_thenDoesNotShowCondition() {
        // given
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100)]
        var path = Path()
        path.move(to: points[0])
        path.addLine(to: points[1])
        path.addLine(to: points[2])
        let arrow = WorkflowArrowHover.Candidate(id: "bent", path: path, points: points)
        // when / then
        #expect(WorkflowArrowHover.nearest(to: CGPoint(x: 50, y: 50), candidates: [arrow]) == nil)
        #expect(WorkflowArrowHover.nearest(to: CGPoint(x: 99, y: 50), candidates: [arrow]) == "bent")
    }

    @Test func givenZoomAndScroll_whenPlacingTooltip_thenConvertsToViewportAndFlipsAtEdges() {
        // given
        let cursor = WorkflowArrowHover.viewportPoint(logical: CGPoint(x: 675, y: 425), scale: 2,
                                                      visibleOrigin: CGPoint(x: 600, y: 400))
        // when
        let center = WorkflowArrowHover.tooltipCenter(cursor: cursor, size: CGSize(width: 260, height: 60), viewport: CGSize(width: 800, height: 500))
        // then
        #expect(cursor == CGPoint(x: 750, y: 450))
        #expect(center == CGPoint(x: 606, y: 406))
        let clamped = WorkflowArrowHover.tooltipCenter(cursor: CGPoint(x: -40, y: -20), size: CGSize(width: 260, height: 60),
                                                       viewport: CGSize(width: 800, height: 500))
        #expect(clamped.x >= 138 && clamped.y >= 38)
    }
}
