import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct PendingMessageTests {
    @Test func givenNonliveBuilderFollowup_whenTaskStartedReceiptsArrive_thenExactPendingIDsDisappear() throws {
        // given
        let snapshot = try #require(TaskInfo(.object(["task_id": .string("task"), "pending_messages": .array([
            .object(["id": .string("consumed"), "text": .string("same feedback"), "status": .string("pending")]),
            .object(["id": .string("still-queued"), "text": .string("same feedback"), "status": .string("pending")])
        ])])))
        let started = try #require(TaskEvent(line: #"{"v":1,"seq":1,"kind":"task_started","prompt":"same feedback","message_ids":["consumed"]}"#))
        // when / then
        #expect(PendingMessage.visible(snapshot: snapshot, events: [started]).map(\.id) == ["still-queued"])
    }

    @Test func givenRepeatedTextWithDistinctQueueIDs_whenOneDeliveryArrives_thenOnlyMatchingPendingBubbleDisappears() throws {
        // given
        let snapshot = try #require(TaskInfo(.object(["task_id": .string("task"), "pending_messages": .array([
            .object(["id": .string("first"), "text": .string("same feedback"), "status": .string("pending")]),
            .object(["id": .string("second"), "text": .string("same feedback"), "status": .string("pending")])
        ])])))
        let event = try #require(TaskEvent(line: #"{"v":1,"seq":1,"kind":"user_message","text":"same feedback","message_id":"first"}"#))
        // when / then
        #expect(PendingMessage.visible(snapshot: snapshot, events: []).map(\.id) == ["first", "second"])
        #expect(PendingMessage.visible(snapshot: snapshot, events: [event]).map(\.id) == ["second"])
    }

    @Test func givenBuilderAliasAndConsumedFollowup_whenDeliveryArrives_thenCanonicalQueuedBubbleIsDeduplicated() throws {
        // given
        let snapshot = try #require(TaskInfo(.object(["task_id": .string("task"), "pending_messages": .array([
            .object(["id": .string("builder-1"), "delivery_id": .string("inbox-1"), "text": .string("first"), "status": .string("pending")]),
            .object(["id": .string("builder-2"), "text": .string("second"), "status": .string("pending")])
        ])])))
        let events = try [
            #"{"v":1,"seq":1,"kind":"undelivered","message_id":"inbox-1"}"#,
            #"{"v":1,"seq":2,"kind":"user_message","text":"followup","message_ids":["builder-2"]}"#
        ].map { try #require(TaskEvent(line: $0)) }
        // when / then
        #expect(PendingMessage.visible(snapshot: snapshot, events: events).isEmpty)
        #expect(PendingMessage.visible(snapshot: nil, events: []).isEmpty)
    }
}
