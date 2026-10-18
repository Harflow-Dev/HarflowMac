import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

extension WorkflowTests {
    @Test func givenStartNode_whenUpdatingWorkflowPrompt_thenPurposePersistsWithoutChangingOtherSettings() {
        // given
        let harness = makeVM()
        harness.sut.definition = WorkflowVM.starterDefinition()
        let original = harness.sut.definition
        // when
        harness.sut.updateNode("start", key: "prompt", value: .string("Plan, implement, and review the requested change"))
        // then
        #expect(harness.sut.nodes.first { $0.id == "start" }?.raw["prompt"]?.stringValue == "Plan, implement, and review the requested change")
        #expect(harness.sut.definition["connections"] == original["connections"])
        #expect(harness.sut.nodes.first { $0.id == "start" }?.type == "start")
    }

}
