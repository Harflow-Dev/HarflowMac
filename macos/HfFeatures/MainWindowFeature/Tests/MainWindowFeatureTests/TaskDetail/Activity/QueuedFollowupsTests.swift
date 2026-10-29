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
            item("c", 3, "consumed", text: "Included once.", extra: ["successor_task_id": .string("s1")]),
            item("e", 5, "delivery_unknown", text: "maybe", extra: ["reason": .string("spawn interrupted")]),
            item("f", 6, "cancelled"),
            item("g", 7, "mystery", text: "ignored")
        ])])
        // when
        let bubbles = WorkMessageBubble.project(raw: ["queued_followups": ledger])
        // then
        #expect(bubbles.map(\.id) == ["a", "b", "d", "e"])
        #expect(bubbles[0].caption == "Queued" && bubbles[0].text == "  keep  spacing\n" && bubbles[0].isPinned && bubbles[0].canCancel)
        #expect(bubbles[1].caption == "Queued" && bubbles[1].isPinned && !bubbles[1].canCancel)
        #expect(bubbles[2].caption == "Undeliverable" && bubbles[2].note == "superseded by s2; resend to it" && !bubbles[2].isPinned)
        #expect(bubbles[3].caption == "Delivery uncertain" && bubbles[3].note == "spawn interrupted" && !bubbles[3].canCancel)
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
        let queued = WorkMessageBubble.project(raw: info.raw)
        // then
        #expect(bubbles.map(\.id) == ["p"])
        #expect(bubbles[0].caption == "Pending" && bubbles[0].successorTaskID == nil)
        #expect(queued.map(\.id) == ["q"] && queued[0].caption == "Queued")
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
