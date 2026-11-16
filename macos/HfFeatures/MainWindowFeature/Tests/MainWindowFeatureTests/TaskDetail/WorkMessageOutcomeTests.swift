@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkMessageOutcomeTests

struct WorkMessageOutcomeTests {
    @Test(arguments: ["delivering", "delivered"])
    func givenContinuationUncertaintyWithRefusalAndNote_whenPresented_thenBothEngineExplanationsRemain(status: String) {
        // given
        let explanation = "Continuation outcome is uncertain."
        let note = "Do not resend automatically; reconcile the successor first."
        let raw: [String: JSONValue] = ["status": .string(status), "note": .string(note),
                                       "refusal": .object(["code": .string("continuation_uncertain"), "message": .string(explanation)])]
        // when / then
        #expect(WorkMessageOutcome.describe(raw) == explanation + "\n" + note)
        #expect(WorkMessageBubble.refusalNote(in: raw) == explanation + "\n" + note)
    }

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

    @Test func givenEngineCancelResult_whenDescribed_thenStatusRatherThanLocalSuccessDecidesOutcome() {
        // given / when / then
        #expect(WorkMessageOutcome.describe(["status": .string("cancelled")]) == "Queued message cancelled.")
        #expect(WorkMessageOutcome.describe(["status": .string("delivering")]) == "Delivery is in progress.")
        #expect(WorkMessageOutcome.describe(["status": .string("future")]) == "Message delivery status is unavailable.")
    }

    @Test(arguments: ["clean", "refusal", "reason", "workflow_run_id", "workflow_id", "workflow_node_id",
                      "workflow_role", "node_id", "delivery_task_id", "missing-task", "delivering", "now"])
    func givenSettledTargetNote_whenReceiptIsClassified_thenOnlyUnambiguousStandaloneQueueOmitsAdvisory(variant: String) {
        // given
        var raw: [String: JSONValue] = ["task_id": .string("source"), "status": .string("queued"),
            "delivery": .string("queue"), "target_settled": .bool(true), "note": .string("Engine advisory")]
        switch variant {
        case "refusal": raw["refusal"] = .object(["message": .string("Refused")])
        case "reason": raw["reason"] = .string("Uncertain")
        case "missing-task": raw["task_id"] = nil
        case "delivering": raw["status"] = .string("delivering")
        case "now": raw["delivery"] = .string("now")
        case "clean": break
        default: raw[variant] = .string("workflow identity")
        }
        // when / then
        #expect(WorkMessageOutcome.describe(raw).contains("Engine advisory") == (variant != "clean"))
        #expect((WorkMessageBubble.refusalNote(in: raw)?.contains("Engine advisory") == true) == (variant != "clean"))
        if variant == "clean" { #expect(WorkMessageOutcome.describe(raw) == "Queued — not yet delivered.") }
    }

}
