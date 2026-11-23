@testable import HfRepository
import MonitorCore
import Testing

@Suite struct StoreAttentionTests {
    private func refusal(code: String = "state_incompatible", message: String, data: [String: JSONValue]) -> ToolError {
        .structuredRefusal(code: code, message: message, data: data)
    }

    @Test func givenAForeignStoreRefusal_whenBuilding_thenTheTitleIsGenericAndTheRowsAreRootAndReason() {
        // given
        let error = refusal(message: "Unsupported state root: foreign store marker", data: [
            "reason": .string("foreign_store"), "state_root": .string("/tmp/harflow-state")
        ])

        // when
        let sut = StoreAttention.from(refusal: error)

        // then
        #expect(sut?.title == "Task store needs attention")
        #expect(sut?.message == "Unsupported state root: foreign store marker")
        #expect(sut?.stateRoot == "/tmp/harflow-state")
        #expect(sut?.reason == "foreign_store")
        #expect(sut?.code == nil)
    }

    @Test func givenAMissingRootRefusal_whenBuilding_thenTheNotCreatedTitleShows() {
        // given
        let error = refusal(message: "No store.", data: ["reason": .string("missing_root")])

        // when
        let sut = StoreAttention.from(refusal: error)

        // then
        #expect(sut?.title == "Task store has not been created")
        #expect(sut?.isInterrupted == false)
    }

    @Test func givenAnInterruptedRefusal_whenBuilding_thenTheInterruptedTitleShows() {
        // given
        let error = refusal(message: "Explicit recovery must be resumed", data: ["reason": .string("recovery_interrupted")])

        // when
        let sut = StoreAttention.from(refusal: error)

        // then
        #expect(sut?.title == "Recovery was interrupted")
        #expect(sut?.isInterrupted == true)
        #expect(sut?.code == nil)
    }

    @Test func givenARefusalWithoutAReason_whenBuilding_thenTheCodeIsKeptOnADetailLine() {
        // given
        let error = refusal(message: "Store refused.", data: ["state_root": .string("/tmp/harflow-state")])

        // when
        let sut = StoreAttention.from(refusal: error)

        // then
        #expect(sut?.title == "Task store needs attention")
        #expect(sut?.message == "Store refused.")
        #expect(sut?.reason == nil)
        #expect(sut?.code == "state_incompatible")
        #expect(sut?.stateRoot == "/tmp/harflow-state")
    }

    @Test func givenAnErrorThatIsNotAStoreRefusal_whenBuilding_thenThereIsNoAttention() {
        // given / when / then
        #expect(StoreAttention.from(refusal: .refused(code: "unknown_task", message: "x")) == nil)
        #expect(StoreAttention.from(refusal: .timedOut(tool: "harflow-ctl", seconds: 1)) == nil)
    }

    // MARK: - Inspection

    private func inspection(status: String, reason: String, message: String = "Store inspected.") -> StateInspection {
        StateInspection([
            "state_root": .string("/tmp/harflow-state"), "engine_version": .string("0.0.2"), "status": .string(status),
            "reason": .string(reason), "message": .string(message),
            "recovery_supported": .bool(false), "cooperative_ownership_only": .bool(true)
        ])!
    }

    @Test func givenAnIncompatibleInspection_whenBuilding_thenTheGenericTitleAndTheEngineReasonShow() {
        // given
        let value = inspection(status: "incompatible", reason: "foreign_store", message: "Unsupported state root: foreign store marker")

        // when
        let sut = StoreAttention.from(inspection: value)

        // then
        #expect(sut?.title == "Task store needs attention")
        #expect(sut?.message == "Unsupported state root: foreign store marker")
        #expect(sut?.stateRoot == "/tmp/harflow-state")
        #expect(sut?.reason == "foreign_store")
        #expect(sut?.code == nil)
    }

    @Test func givenAnInterruptedInspection_whenBuilding_thenTheInterruptedTitleShows() {
        // given
        let value = inspection(status: "interrupted", reason: "recovery_interrupted", message: "Explicit recovery must be resumed")

        // when
        let sut = StoreAttention.from(inspection: value)

        // then
        #expect(sut?.title == "Recovery was interrupted")
        #expect(sut?.isInterrupted == true)
    }

    @Test(arguments: [("ready", "compatible"), ("missing", "missing_root")])
    func givenAReadyOrMissingInspection_whenBuilding_thenThereIsNoAttention(status: String, reason: String) {
        // given
        let value = inspection(status: status, reason: reason)

        // when / then
        #expect(StoreAttention.from(inspection: value) == nil)
    }
}
