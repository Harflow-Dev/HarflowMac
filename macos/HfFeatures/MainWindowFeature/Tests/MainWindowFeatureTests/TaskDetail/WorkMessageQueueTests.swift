@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkMessageQueueTests

@MainActor
struct WorkMessageQueueTests {
    @Test func givenWorkflowMessageStates_whenProjected_thenOnlyQueuedItemsCanBeCancelled() {
        // given
        let raw: [String: JSONValue] = ["messages": .array([
            .object(["id": .string("one"), "status": .string("queued"), "text": .string("  exact text  ")]),
            .object(["id": .string("two"), "status": .string("delivering")]),
            .object(["id": .string("three"), "status": .string("delivered")])])]
        // when
        let items = WorkMessageQueue.items(raw: raw)
        // then
        #expect(items.map(\.id) == ["one", "two", "three"])
        #expect(items.first?.text == "  exact text  ")
        #expect(items.map(\.canCancel) == [true, false, false])
    }

    @Test func givenQueuedThenDeliveredAndCancelled_whenProjected_thenDeliveredAndCancelledAreOmitted() {
        // given
        let queued: [String: JSONValue] = ["messages": .array([
            .object(["id": .string("b"), "seq": .number(2), "status": .string("queued"), "text": .string("second")]),
            .object(["id": .string("a"), "seq": .number(1), "status": .string("queued"), "text": .string("first")])])]
        let delivered: [String: JSONValue] = ["messages": .array([
            .object(["id": .string("a"), "seq": .number(1), "status": .string("delivered"), "text": .string("first")])])]
        let cancelled: [String: JSONValue] = ["messages": .array([
            .object(["id": .string("a"), "seq": .number(1), "status": .string("cancelled")])])]
        let refusal: [String: JSONValue] = ["messages": .array([
            .object(["id": .string("a"), "seq": .number(1), "status": .string("queued"), "text": .string("now"),
                     "refusal": .object(["code": .string("interrupt_unsupported"), "message": .string("busy")])])])]
        // when
        let waiting = WorkMessageBubble.project(raw: queued)
        let settled = WorkMessageBubble.project(raw: delivered)
        let withdrawn = WorkMessageBubble.project(raw: cancelled)
        let refused = WorkMessageBubble.project(raw: refusal)
        // then
        #expect(waiting.map(\.id) == ["a", "b"])
        #expect(waiting.allSatisfy { $0.caption == "Queued" && $0.canCancel && $0.isPinned })
        #expect(settled.isEmpty)
        #expect(withdrawn.isEmpty)
        #expect(refused.first?.canCancel == true)
        #expect(refused.first?.note == "Send now isn't available. This operation can't be interrupted safely.")
    }

    @Test func givenMessagesAndFollowups_whenProjected_thenMessagesWin() {
        // given
        let raw: [String: JSONValue] = [
            "messages": .array([.object(["id": .string("m"), "seq": .number(1), "status": .string("delivering"), "text": .string("held")])]),
            "queued_followups": .object(["state": .string("available"), "items": .array([
                .object(["id": .string("f"), "seq": .number(1), "status": .string("queued"), "text": .string("other")])])])]
        // when
        let bubbles = WorkMessageBubble.project(raw: raw)
        // then
        #expect(bubbles.map(\.id) == ["m"])
        #expect(bubbles.first?.canCancel == false && bubbles.first?.caption == "Queued")
    }

    // MARK: - Settled and pinned classification

    private func message(_ id: String, _ seq: Int, _ status: String, reason: String? = nil) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "seq": .number(Double(seq)), "status": .string(status), "text": .string(id)]
        if let reason { object["reason"] = .string(reason) }
        return .object(object)
    }

    @Test(arguments: ["delivered", "consumed"])
    func givenCompletedStatusInMessagesKey_whenProjected_thenRecordIsOmitted(status: String) {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("a", 1, status), message("b", 2, "queued")])]
        // when
        let bubbles = WorkMessageBubble.project(raw: raw)
        // then
        #expect(bubbles.map(\.id) == ["b"])
    }

    @Test(arguments: ["delivered", "consumed"])
    func givenCompletedStatusInFollowupLedger_whenProjected_thenRecordIsOmitted(status: String) {
        // given
        let ledger: JSONValue = .object(["state": .string("available"), "items": .array([
            message("a", 1, status), message("b", 2, "queued")])])
        // when
        let bubbles = WorkMessageBubble.project(raw: ["queued_followups": ledger])
        // then
        #expect(bubbles.map(\.id) == ["b"])
    }

    @Test(arguments: ["delivered", "consumed", "cancelled"])
    func givenOmittedStatusAsQueueItem_whenProjected_thenNoBubbleIsProduced(status: String) {
        // given
        let items = [WorkMessageQueue.Item(id: "a", text: "x", status: status, reason: nil)]
        // when
        let bubbles = WorkMessageBubble.project(items: items)
        // then
        #expect(bubbles.isEmpty)
    }

    @Test func givenEveryItemStatus_whenProjectedFromItems_thenPinnedAndSettledAreClassified() {
        // given
        let items = ["queued", "delivering", "reserved", "undeliverable", "delivery_unknown", "delivered", "consumed"].map {
            WorkMessageQueue.Item(id: $0, text: $0, status: $0, reason: $0 == "undeliverable" ? "gone" : nil)
        }
        // when
        let bubbles = WorkMessageBubble.project(items: items)
        // then
        #expect(bubbles.map(\.id) == ["queued", "delivering", "reserved", "undeliverable", "delivery_unknown"])
        #expect(bubbles.map(\.isPinned) == [true, true, true, false, false])
        #expect(bubbles.map(\.canCancel) == [true, false, false, false, false])
        #expect(bubbles[3].note == "gone")
    }

    @Test func givenOnlyCompletedRecords_whenProjected_thenResultIsEmpty() {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("a", 1, "delivered"), message("b", 2, "consumed")])]
        // when / then
        #expect(WorkMessageBubble.project(raw: raw).isEmpty)
        #expect(WorkMessageBubble.project(raw: [:]).isEmpty)
    }

    @Test func givenUnavailableLedger_whenProjected_thenNothingIsShown() {
        // given
        let ledger: JSONValue = .object(["state": .string("unavailable"), "items": .array([message("a", 1, "queued")])])
        // when / then
        #expect(WorkMessageBubble.project(raw: ["queued_followups": ledger]).isEmpty)
    }

    @Test func givenUnknownStatus_whenProjected_thenReadOnlyBubblePreservesEvidence() {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("future", 1, "future-status")])]
        // when
        let bubble = WorkMessageBubble.project(raw: raw).first
        // then
        #expect(bubble?.kind == .unknown("future-status"))
        #expect(bubble?.canCancel == false)
    }

    @Test func givenStandaloneDeliveringReason_whenProjected_thenDeliveryIsUncertain() {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("uncertain", 1, "delivering", reason: "inspect")])]
        // when
        let bubble = WorkMessageBubble.project(raw: raw).first
        // then
        #expect(bubble?.kind == .uncertain("inspect"))
        #expect(bubble?.canCancel == false)
    }

    @Test func givenWorkflowDeliveringReason_whenProjectedThroughItems_thenNotStandaloneUncertainty() {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("workflow", 1, "delivering", reason: "engine note")])]
        let items = WorkMessageQueue.items(raw: raw, source: .workflowRun)
        // when
        let bubble = WorkMessageBubble.project(items: items).first
        // then
        #expect(bubble?.kind == .queued(canCancel: false, note: nil))
    }

    @Test func givenUncertainDelivery_whenProjected_thenApprovedCopyPrecedesEngineReason() {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("m", 1, "delivering", reason: "Engine explanation")])]
        // when
        let bubble = WorkMessageBubble.project(raw: raw).first
        // then
        #expect(bubble?.isPinned == false)
        #expect(bubble?.canCancel == false)
        #expect(bubble?.note == "Delivery could not be confirmed. The message is not requeued.\nEngine explanation")
    }

    @Test(arguments: ["delivering", "delivered", "cancelled"])
    func givenCurrentLedgerPhase_whenProjectingOutcome_thenPhaseCopyHasNoMessageText(status: String) {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("sensitive text", 1, status)])]
        // when
        let outcome = WorkMessageOutcome.ledger(raw)
        // then
        #expect(outcome == ["delivering": "Delivery is in progress.", "delivered": "Message delivered.", "cancelled": "Queued message cancelled."][status])
        #expect(outcome?.contains("sensitive text") == false)
    }

    @Test(arguments: ["queued", "delivery_unknown", "future-status"])
    func givenOlderSettlementAndNewerMessage_whenProjectingPhase_thenOlderOutcomeIsSuppressed(status: String) {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("old", 1, "delivered"), message("new", 2, status)])]
        // when / then
        #expect(WorkMessageOutcome.ledger(raw) == nil)
    }

    @Test func givenRemainingQueuedAndLaterCancellation_whenProjectingPhase_thenCancelledOutcomeIsShown() {
        // given
        let raw: [String: JSONValue] = ["messages": .array([message("remaining", 1, "queued"), message("cancelled", 2, "cancelled")])]
        // when / then
        #expect(WorkMessageOutcome.ledger(raw) == "Queued message cancelled.")
        #expect(WorkMessageBubble.project(raw: raw).map(\.id) == ["remaining"])
    }
}
