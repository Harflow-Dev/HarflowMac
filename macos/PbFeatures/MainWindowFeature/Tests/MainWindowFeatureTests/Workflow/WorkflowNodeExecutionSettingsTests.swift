@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowNodeExecutionSettingsTests

struct WorkflowNodeExecutionSettingsTests {
    @Test func givenSerialPredecessor_whenSessionOptionsPresented_thenPreviousSessionIsAvailable() {
        // given
        let node = WorkflowNodeModel(raw: ["id": .string("publish"), "type": .string("agent")])
        let definition: [String: JSONValue] = ["nodes": .array([
            .object(["id": .string("draft"), "type": .string("agent")]), .object(node.raw)
        ]), "connections": .array([.object(["source": .string("draft"), "target": .string("publish")])])]
        // when / then
        #expect(WorkflowNodeExecutionSettings.canContinuePrevious(node, definition: definition))
    }

    @Test(arguments: ["start", "parallel_end"])
    func givenStructuralPredecessor_whenSessionOptionsPresented_thenPreviousSessionIsUnavailable(type: String) {
        // given
        let node = WorkflowNodeModel(raw: ["id": .string("next"), "type": .string("agent")])
        let definition: [String: JSONValue] = ["nodes": .array([
            .object(["id": .string("previous"), "type": .string(type)]), .object(node.raw)
        ]), "connections": .array([.object(["source": .string("previous"), "target": .string("next")])])]
        // when / then
        #expect(!WorkflowNodeExecutionSettings.canContinuePrevious(node, definition: definition))
    }

    @Test func givenConvergingPredecessors_whenSessionOptionsPresented_thenNoAmbiguousSessionOffered() {
        // given
        let node = WorkflowNodeModel(raw: ["id": .string("next")])
        let definition: [String: JSONValue] = ["nodes": .array([
            .object(["id": .string("a"), "type": .string("agent")]), .object(["id": .string("b"), "type": .string("agent")]), .object(node.raw)
        ]), "connections": .array([
            .object(["source": .string("a"), "target": .string("next")]), .object(["source": .string("b"), "target": .string("next")])
        ])]
        // when / then
        #expect(!WorkflowNodeExecutionSettings.canContinuePrevious(node, definition: definition))
    }

    @Test func givenSelectedExclusiveRoute_whenSessionOptionsPresented_thenPreviousSessionIsAvailable() {
        // given
        let node = WorkflowNodeModel(raw: ["id": .string("next")])
        let definition: [String: JSONValue] = ["nodes": .array([
            .object(["id": .string("previous"), "type": .string("agent")]), .object(node.raw)
        ]), "connections": .array([
            .object(["source": .string("previous"), "target": .string("next")]),
            .object(["source": .string("previous"), "target": .string("end")]),
            .object(["source": .string("review"), "target": .string("next"), "backward": .bool(true)])
        ])]
        // when / then
        #expect(WorkflowNodeExecutionSettings.canContinuePrevious(node, definition: definition))
    }

    @MainActor @Test func givenNewVisit_whenAttemptPresented_thenNumberResetsAndHistoricalRunsRemainReadable() {
        // given
        let harness = WorkflowTests().makeVM()
        harness.sut.selectedRun = WorkflowRunModel(raw: ["activations": .array([
            .object(["node_id": .string("implementation"), "role": .string("node"), "attempt_in_visit": .number(3)]),
            .object(["node_id": .string("implementation"), "role": .string("node"), "attempt_in_visit": .number(1)])
        ])])
        // when / then
        #expect(harness.sut.nodeAttempt("implementation") == 1)
        harness.sut.selectedRun = WorkflowRunModel(raw: ["activations": .array([
            .object(["node_id": .string("implementation"), "role": .string("node")]),
            .object(["node_id": .string("implementation"), "role": .string("node")])
        ])])
        #expect(harness.sut.nodeAttempt("implementation") == 2)
    }

    @Test func givenExistingSeconds_whenUnitChanged_thenDurationIsPreservedWithoutRounding() {
        // given
        let seconds = 90
        // when / then
        #expect(WorkflowTimeoutUnit.preferred(for: seconds) == .seconds)
        #expect(WorkflowTimeoutUnit.minutes.value(for: seconds) == 1.5)
        #expect(WorkflowTimeoutUnit.minutes.seconds(for: 1.5) == seconds)
        #expect(WorkflowTimeoutUnit.hours.seconds(for: 1.5) == 5400)
        #expect(WorkflowTimeoutUnit.preferred(for: 900) == .minutes)
        #expect(WorkflowTimeoutUnit.preferred(for: 7200) == .hours)
    }

    @Test(arguments: [0.0, -1, Double.nan, Double.infinity, 86401])
    func givenInvalidTypedDuration_whenConverted_thenSavedLimitIsNotReplaced(value: Double) {
        // given / when / then
        #expect(WorkflowTimeoutUnit.seconds.seconds(for: value) == nil)
    }

    @Test func givenFractionalDuration_whenConverted_thenNearestWholeSecondIsStored() {
        // given / when / then
        #expect(WorkflowTimeoutUnit.minutes.seconds(for: 1.25) == 75)
        #expect(WorkflowTimeoutUnit.seconds.seconds(for: 1.5) == 2)
        #expect(WorkflowTimeoutUnit.hours.seconds(for: Double.greatestFiniteMagnitude) == nil)
    }

    @Test func givenNoTimeout_whenSettingsPresented_thenLimitIsDisabled() {
        // given
        let node = WorkflowNodeModel(raw: ["id": .string("review")])
        // when / then
        #expect(WorkflowNodeExecutionSettings.timeoutSeconds(node) == nil)
        #expect(WorkflowNodeExecutionSettings.timeoutSeconds(.init(raw: ["timeout_seconds": .number(900)])) == 900)
    }
}
