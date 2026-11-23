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
}
