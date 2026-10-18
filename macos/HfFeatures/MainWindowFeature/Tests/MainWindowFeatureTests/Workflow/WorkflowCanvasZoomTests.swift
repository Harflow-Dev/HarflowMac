import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - WorkflowCanvasZoomTests

@Suite struct WorkflowCanvasZoomTests {
    @Test func givenZoomButtons_whenSteppingPastBounds_thenStopsAtFiftyAndTwoHundredPercent() {
        // given / when / then
        #expect(WorkflowCanvasZoom.adjusted(1, steps: 1) == 1.25)
        #expect(WorkflowCanvasZoom.adjusted(1, steps: -1) == 0.75)
        #expect(WorkflowCanvasZoom.adjusted(0.5, steps: -1) == 0.5)
        #expect(WorkflowCanvasZoom.adjusted(2, steps: 1) == 2)
    }

    @Test func givenDifferentZoomLevels_whenMovingPointer_thenSameLogicalMovementAndGridSnapArePreserved() {
        // given
        let origin = CGPoint(x: 60, y: 100)
        // when / then
        for scale: CGFloat in [0.5, 1, 1.25, 2] {
            let displayTranslation = CGSize(width: 37 * scale, height: 26 * scale)
            let logicalTranslation = WorkflowCanvasZoom.logical(displayTranslation, scale: scale)
            let moved = CGPoint(x: origin.x + logicalTranslation.width, y: origin.y + logicalTranslation.height)
            #expect(WorkflowCanvasGeometry.snapped(moved) == CGPoint(x: 100, y: 130))
            let displayedPort = CGPoint(x: 560 * scale, y: 146 * scale)
            #expect(WorkflowCanvasZoom.logical(displayedPort, scale: scale) == CGPoint(x: 560, y: 146))
        }
    }

    @Test func givenZoomedOutCanvas_whenCalculatingScrollBounds_thenBlankViewportRemainsADropTarget() {
        // given
        let viewport = CGSize(width: 1000, height: 800)
        let extent = CGSize(width: 900, height: 330)
        // when / then
        for scale: CGFloat in [0.5, 1, 2] {
            let size = WorkflowCanvasZoom.contentSize(extent: extent, viewport: viewport, scale: scale)
            #expect(size.width * scale >= viewport.width)
            #expect(size.height * scale >= viewport.height)
            #expect(size.width >= extent.width)
            #expect(size.height >= extent.height)
        }
    }
}
