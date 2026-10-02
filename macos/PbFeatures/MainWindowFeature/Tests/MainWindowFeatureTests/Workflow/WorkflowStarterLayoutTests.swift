import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - WorkflowStarterLayoutTests

@MainActor
@Suite struct WorkflowStarterLayoutTests {
    @Test func givenNewWorkflow_whenBuildingStarter_thenNodesShareACenterLineAndEqualGaps() {
        // given
        let nodes = WorkflowJSON.nodes(WorkflowVM.starterDefinition())
        // when
        let centers = nodes.map { WorkflowCanvasGeometry.center($0).y }
        let gaps = zip(nodes, nodes.dropFirst()).map { left, right in
            right.position.x - left.position.x - WorkflowCanvasGeometry.size(left).width
        }
        // then
        #expect(nodes.map(\.id) == ["start", "planning", "implementation", "review", "end"])
        #expect(centers.allSatisfy { $0 == centers.first })
        #expect(gaps.allSatisfy { $0 == 50 })
        #expect(nodes.first { $0.id == "planning" }?.raw["title"]?.stringValue == "Plan")
        let edges = WorkflowJSON.edges(WorkflowVM.starterDefinition())
        #expect(edges.contains { $0.source == "review" && $0.target == "implementation" && !$0.condition.isEmpty })
        #expect(edges.contains { $0.source == "review" && $0.target == "end" && !$0.condition.isEmpty })
        #expect(nodes.allSatisfy { $0.position.x >= 0 && $0.position.y >= 0 })
    }
}
