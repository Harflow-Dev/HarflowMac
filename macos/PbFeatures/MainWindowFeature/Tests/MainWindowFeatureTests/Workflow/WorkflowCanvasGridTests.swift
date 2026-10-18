import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - WorkflowCanvasGridTests

struct WorkflowCanvasGridTests {
    @Test(arguments: [0.25, 0.5, 0.75, 1.0, 1.25, 1.75, 2.0])
    func givenZoom_whenDrawingDots_thenScreenDensityAndSizeRemainStable(scale: Double) {
        // given / when
        let spacing = WorkflowCanvasGrid.spacing(scale: scale)
        // then
        #expect(spacing * scale >= 20)
        #expect(spacing.truncatingRemainder(dividingBy: 10) == 0)
        #expect(abs(WorkflowCanvasGrid.diameter(scale: scale) * scale - 1.7) < 0.001)
        let viewport = CGSize(width: 1200 / scale, height: 800 / scale)
        let count = (Int(viewport.width / spacing) + 1) * (Int(viewport.height / spacing) + 1)
        #expect(count <= 2501)
    }

    @Test func givenScrolledHugeCanvas_whenFirstDotComputed_thenWorldCoordinatesStayGridAligned() {
        // given
        let visible = CGRect(x: 100013, y: 400017, width: 1200, height: 800)
        let spacing = WorkflowCanvasGrid.spacing(scale: 1)
        // when
        let first = WorkflowCanvasGrid.firstLocalDot(in: visible, spacing: spacing)
        // then
        #expect((visible.minX + first.x).truncatingRemainder(dividingBy: spacing) == 0)
        #expect((visible.minY + first.y).truncatingRemainder(dividingBy: spacing) == 0)
        #expect(first.x >= 0 && first.x < spacing)
        #expect(first.y >= 0 && first.y < spacing)
    }

    @Test func given175PercentZoomAndScrolledViewport_whenScreenDotsBuilt_thenVisibleWorldAlignedDotsRemainBounded() {
        // given
        let viewport = CGRect(x: 17513, y: 7017, width: 1200, height: 800)
        let scale = 1.75
        // when
        let points = WorkflowCanvasGrid.screenDots(viewport: viewport, scale: scale, content: CGSize(width: 1000000, height: 1000000))
        // then
        #expect(!points.isEmpty)
        #expect(points.count <= 2501)
        #expect(points.allSatisfy { $0.x >= 0 && $0.y >= 0 && $0.x <= 1200 && $0.y <= 800 })
        #expect(points.allSatisfy { point in
            let worldX = (point.x + viewport.minX) / scale
            let worldY = (point.y + viewport.minY) / scale
            return abs(worldX.truncatingRemainder(dividingBy: 20)) < 0.001
            && abs(worldY.truncatingRemainder(dividingBy: 20)) < 0.001
        })
    }

}
