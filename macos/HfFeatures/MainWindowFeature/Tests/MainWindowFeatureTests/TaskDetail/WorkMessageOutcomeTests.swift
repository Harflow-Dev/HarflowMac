@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkMessageOutcomeTests

struct WorkMessageOutcomeTests {
    @Test(arguments: ["delivering", "delivered"])
    func givenContinuationWasClaimedBeforeLaunchError_whenDescribed_thenUncertaintyNeverClaimsQueued(_ status: String) {
        // given
        let explanation = "Continuation requires inspection before resending."
        let result: [String: JSONValue] = ["status": .string(status), "refusal": .object([
            "code": .string("continuation_uncertain"), "message": .string(explanation)])]
        // when / then
        #expect(WorkMessageOutcome.describe(result) == explanation)
        #expect(WorkMessageOutcome.notice(result) == explanation)
    }

    @Test func givenUnsafeInterruptLeavesMessageQueued_whenDescribed_thenQueuedStateAndReasonArePreserved() {
        // given
        let result: [String: JSONValue] = ["status": .string("queued"), "refusal": .object([
            "code": .string("interrupt_unsupported"), "message": .string("Safe interruption is unavailable.")])]
        // when / then
        #expect(WorkMessageOutcome.describe(result) == "Queued — Safe interruption is unavailable.")
    }

    @Test func givenWorkflowEndedBeforeDispatch_whenDescribed_thenUndeliverableReasonRemainsVisible() {
        // given
        let result: [String: JSONValue] = ["status": .string("undeliverable"), "reason": .string("The workflow ended.")]
        // when / then
        #expect(WorkMessageOutcome.describe(result) == "Undeliverable — The workflow ended.")
        #expect(WorkMessageOutcome.notice(result) == "Undeliverable — The workflow ended.")
    }

    @Test func givenQueuedMessageWithoutRefusal_whenDescribed_thenWorkflowDoesNotShowAnError() {
        // given
        let result: [String: JSONValue] = ["status": .string("queued")]
        // when / then
        #expect(WorkMessageOutcome.describe(result) == "Queued — not yet delivered.")
        #expect(WorkMessageOutcome.notice(result) == nil)
    }
}
