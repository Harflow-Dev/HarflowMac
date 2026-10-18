@testable import MainWindowFeature
import MonitorCore
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowCanvasNodeHitShapeTests

struct WorkflowCanvasNodeHitShapeTests {
    @Test(arguments: ["start", "end"])
    func givenCompactCapsuleNode_whenHitShapeIsEvaluated_thenOriginalRoundedRectangleCornersRemainReachable(role: String) throws {
        // given
        let node = WorkflowNodeModel(raw: ["id": .string(role), "type": .string(role)])
        let bounds = CGRect(origin: .zero, size: WorkflowCanvasGeometry.size(node))

        // when
        let hitPath = WorkflowCanvasNode.hitShape.path(in: bounds)
        let originalPath = RoundedRectangle(cornerRadius: PbRadius.card).path(in: bounds)
        let capsulePath = Capsule().path(in: bounds)

        // then: the visual capsule must not shrink the original click/drag footprint.
        #expect(bounds.size == CGSize(width: 72, height: 72))
        for point in [CGPoint(x: 8, y: 8), CGPoint(x: 64, y: 8), CGPoint(x: 8, y: 64), CGPoint(x: 64, y: 64)] {
            #expect(hitPath.contains(point))
            #expect(originalPath.contains(point))
            #expect(!capsulePath.contains(point))
        }
        for x in stride(from: 0.0, through: 72.0, by: 3) {
            for y in stride(from: 0.0, through: 72.0, by: 3) {
                let point = CGPoint(x: x, y: y)
                #expect(hitPath.contains(point) == originalPath.contains(point))
            }
        }
    }
}
