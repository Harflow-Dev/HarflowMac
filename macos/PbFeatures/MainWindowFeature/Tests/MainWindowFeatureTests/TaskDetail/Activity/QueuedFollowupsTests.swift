import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct QueuedFollowupsTests {
    private func snapshot(_ ledger: JSONValue?) throws -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string("task")]
        if let ledger { object["queued_followups"] = ledger }
        return try #require(TaskInfo(.object(object)))
    }

    private func item(_ id: String, _ seq: Int, _ status: String, text: String? = nil, extra: [String: JSONValue] = [:]) -> JSONValue {
        var object: [String: JSONValue] = ["id": .string(id), "seq": .number(Double(seq)), "status": .string(status)]
        if let text { object["text"] = .string(text) }
        return .object(object.merging(extra) { $1 })
    }

    @Test func givenNoLedgerOrAnUnavailableOne_whenRead_thenNothingIsShown() throws {
        // given / when / then
        #expect(PendingMessage.visible(snapshot: try snapshot(nil), events: []).isEmpty)
        let unavailable = JSONValue.object(["state": .string("unavailable"), "items": .array([item("a", 1, "queued", text: "x")])])
        #expect(PendingMessage.visible(snapshot: try snapshot(unavailable), events: []).isEmpty)
        #expect(PendingMessage.visible(snapshot: nil, events: []).isEmpty)
    }

    @Test func givenEveryStatus_whenRead_thenEachGetsItsBubbleInQueueOrder() throws {
        // given
        let ledger = JSONValue.object(["state": .string("available"), "omitted_final": .number(0), "items": .array([
            item("d", 4, "undeliverable", text: "lost", extra: ["reason": .string("superseded by s2; resend to it")]),
            item("a", 1, "queued", text: "  keep  spacing\n"),
            item("b", 2, "reserved", text: "in flight"),
            item("c", 3, "consumed", extra: ["successor_task_id": .string("s1")]),
            item("e", 5, "delivery_unknown", text: "maybe", extra: ["reason": .string("spawn interrupted")]),
            item("f", 6, "cancelled"),
            item("g", 7, "mystery", text: "ignored")
        ])])
        // when
        let bubbles = PendingMessage.visible(snapshot: try snapshot(ledger), events: [])
        // then
        #expect(bubbles.map(\.id) == ["followup-a", "followup-b", "followup-c", "followup-d", "followup-e", "followup-f"])
        #expect(bubbles[0].caption == "Queued for next continuation" && bubbles[0].text == "  keep  spacing\n" && bubbles[0].isPending)
        #expect(bubbles[1].caption == "Queued for next continuation")
        #expect(bubbles[2].caption == "Sent to s1" && bubbles[2].successorTaskID == "s1" && !bubbles[2].isPending)
        #expect(bubbles.map(\.isPending) == [true, true, false, false, false, false]) // only queued/reserved read as pending
        #expect(bubbles[3].caption == "Undeliverable — superseded by s2; resend to it" && bubbles[3].text == "lost")
        #expect(bubbles[4].caption == "Delivery unknown — spawn interrupted")
        #expect(bubbles[5].caption == "Cancelled")
    }

    @Test func givenLivePendingAndQueuedFollowups_whenRead_thenPendingBubblesAreUnchangedAndComeFirst() throws {
        // given
        let info = try #require(TaskInfo(.object([
            "task_id": .string("task"),
            "pending_messages": .array([.object(["id": .string("p"), "text": .string("live"), "status": .string("pending")])]),
            "queued_followups": .object(["state": .string("available"), "items": .array([item("q", 1, "queued", text: "later")])])
        ])))
        // when
        let bubbles = PendingMessage.visible(snapshot: info, events: [])
        // then
        #expect(bubbles.map(\.id) == ["p", "followup-q"])
        #expect(bubbles[0].caption == "Pending" && bubbles[0].successorTaskID == nil)
    }
}

extension QueuedFollowupsTests {
    @Test func givenBubblesDifferingOnlyInLinkOrStyle_whenTokenised_thenTheTokensDiffer() {
        // given
        let base = PendingMessage(id: "x", text: "t", caption: "c")
        var linked = base
        linked.successorTaskID = "s"
        var settled = base
        settled.isPending = false
        // when / then
        let tokens = [base, linked, settled].map { ActivityUpdateToken(rows: [], liveStep: nil, pendingMessages: [$0]) }
        #expect(Set(tokens.map(\.fingerprint)).count == 3)
    }
}
