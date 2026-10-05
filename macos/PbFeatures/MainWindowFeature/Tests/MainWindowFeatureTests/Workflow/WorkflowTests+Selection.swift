import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowTests selection

extension WorkflowTests {
    @Test func givenMultipleSelectedNodes_whenToggledAndDeleted_thenPrimaryAndIncidentEdgesStayConsistent() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.selectNodes(["implement", "review"], primary: "review")
        // when
        vm.toggleNode("review")
        #expect(vm.selectedNodeID == "implement")
        vm.toggleNode("review")
        vm.connectionSourceID = "implement"
        vm.deleteSelected()
        // then
        #expect(vm.selectedNodeIDs.isEmpty)
        #expect(vm.selectedNodeID == nil)
        #expect(vm.connectionSourceID == nil)
        #expect(!vm.nodes.contains { ["implement", "review"].contains($0.id) })
        #expect(!vm.edges.contains { ["implement", "review"].contains($0.source) || ["implement", "review"].contains($0.target) })
    }

    @Test func givenGroupPositions_whenMoved_thenSharedSnapAndBoundsPreserveOffsets() {
        // given
        let origins = ["a": CGPoint(x: 20, y: 30), "b": CGPoint(x: 95, y: 85)]
        // when
        let positive = WorkflowCanvasSelection.moved(origins: origins, delta: CGSize(width: 16, height: 24))
        let negative = WorkflowCanvasSelection.moved(origins: origins, delta: CGSize(width: -80, height: -90))
        // then
        #expect(positive["a"] == CGPoint(x: 40, y: 50))
        #expect(positive["b"] == CGPoint(x: 115, y: 105))
        #expect(negative["a"] == .zero)
        #expect(negative["b"] == CGPoint(x: 75, y: 55))
    }

    @Test func givenRunGraph_whenMovingOrDeletingMultipleNodes_thenDefinitionIsUnchanged() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.selectedRun = WorkflowRunModel(raw: [:])
        vm.selectNodes(["implement", "review"], primary: "implement")
        let before = vm.definition
        // when
        vm.moveNodes(["implement": .zero, "review": .zero])
        vm.deleteSelected()
        // then
        #expect(vm.definition == before)
    }

    @Test func givenGroupSelection_whenMovingBatch_thenBothPositionsUpdateTogether() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.selectNodes(["implement", "review"], primary: "implement")
        // when
        vm.moveNodes(["implement": CGPoint(x: 100, y: 200), "review": CGPoint(x: 300, y: 200)])
        // then
        #expect(vm.nodes.first { $0.id == "implement" }?.position == CGPoint(x: 100, y: 200))
        #expect(vm.nodes.first { $0.id == "review" }?.position == CGPoint(x: 300, y: 200))
        #expect(vm.selectedNodeIDs == ["implement", "review"])
        vm.selectedNodeID = nil
        #expect(vm.selectedNodeIDs.isEmpty)
    }

}
