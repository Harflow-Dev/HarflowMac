@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowNodeModelTests

struct WorkflowNodeModelTests {
    @Test func givenMissingOptionalField_whenReadingNode_thenRequiredByDefault() {
        // given
        let node = WorkflowNodeModel(raw: ["id": .string("task"), "type": .string("agent")])
        // when / then
        #expect(!node.isOptional)
    }

    @Test func givenAgentOptionalFlag_whenReadingNode_thenOnlyBooleanTrueEnablesOptional() {
        // given
        let values: [JSONValue] = [.bool(true), .bool(false), .string("true"), .null]
        // when
        let actual = values.map { WorkflowNodeModel(raw: ["type": .string("agent"), "optional": $0]).isOptional }
        // then
        #expect(actual == [true, false, false, false])
    }

    @Test func givenTerminalOptionalFlag_whenReadingNode_thenTerminalRemainsRequired() {
        // given
        let terminals = ["start", "end"].map { WorkflowNodeModel(raw: ["type": .string($0), "optional": .bool(true)]) }
        // when / then
        #expect(terminals.allSatisfy { !$0.isOptional })
    }
}
