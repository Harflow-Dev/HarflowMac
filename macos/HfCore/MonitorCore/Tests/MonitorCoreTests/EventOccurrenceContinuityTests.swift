import Foundation
@testable import MonitorCore
import Testing

// MARK: - EventOccurrenceContinuityTests

@Suite
struct EventOccurrenceContinuityTests {
    private func projected(_ seq: Int, id: Int, kind: TaskEvent.Kind) -> TaskEvent {
        TaskEvent(seq: seq, displayID: id, observedAt: nil, sourceTimestamp: nil, kind: kind, rawLine: "normalized")
    }

    private func call(_ seq: Int) -> TaskEvent {
        TaskEvent(line: eventLine(seq, "tool_call", #""call_id": "reused", "tool": "Bash""#))!
    }

    private func result(_ seq: Int) -> TaskEvent {
        TaskEvent(line: eventLine(seq, "tool_result", #""call_id": "reused", "ok": true"#))!
    }

    @Test
    func givenDuplicateRegressingSequences_whenProjected_thenOrderAndOccurrenceIDsRemainDistinct() {
        // given
        let events = [7, 7, 6].enumerated().map { index, seq in
            projected(seq, id: 100 + index, kind: .notice("row \(index)"))
        }
        // when
        let items = Timeline.items(from: events)
        // then
        #expect(events.map(\.seq) == [7, 7, 6])
        #expect(events.map(\.displayID) == [100, 101, 102])
        #expect(items.map(\.id) == [100, 101, 102])
        #expect(items.map(\.body) == [.notice("row 0"), .notice("row 1"), .notice("row 2")])
    }

    @Test
    func givenLegacyAndObservationInitializers_whenConstructed_thenSequenceAndTimestampsStayExplicit() {
        // given
        let date = Date(timeIntervalSince1970: 123)
        let parsed = TaskEvent(line: eventLine(7, "notice", #""text": "legacy""#))!
        let recovery = TaskEvent(displayID: -4, sourceTimestamp: date, kind: .notice("recovery"), rawLine: "raw")
        // when
        let observed = TaskEvent(seq: 7, displayID: 100, observedAt: date, sourceTimestamp: nil, kind: parsed.kind, rawLine: parsed.rawLine)
        // then
        #expect(parsed.displayID == nil)
        #expect(parsed.id == 7)
        #expect(recovery.seq == -4 && recovery.id == -4)
        #expect(recovery.timestamp == date)
        #expect(observed.seq == 7 && observed.id == 100)
        #expect(observed.observedAt == date && observed.sourceTimestamp == nil)
        #expect(observed.rawLine == parsed.rawLine)
    }

    @Test
    func givenObservationGap_whenMatchingResultsAndTextArrive_thenEarlierRowsRemainUnjoined() {
        // given
        var builder = TimelineBuilder()
        let delta = TaskEvent.Kind.assistantDelta(.init(messageID: "message", blockIndex: 0, text: "before"))
        builder.append([call(1), projected(2, id: 102, kind: delta)])
        let before = builder.items
        // when
        builder.breakContinuity()
        builder.append([
            result(3),
            projected(4, id: 104, kind: .assistantDelta(.init(messageID: "message", blockIndex: 0, text: "after"))),
            projected(5, id: 105, kind: .assistantText(text: "final", messageID: "message", blockIndex: 0))
        ])
        // then
        #expect(Array(builder.items.prefix(2)) == before)
        #expect(builder.items.count == 3)
        #expect(builder.items.last?.id == 104)
        #expect(builder.items.last?.body == .text("final", streaming: false))
        #expect(builder.items.first?.isRunningTool == true)
    }

    @Test
    func givenReusedUnresolvedCallID_whenResultsArrive_thenNeitherOccurrenceIsSettled() {
        // given
        var builder = TimelineBuilder()
        builder.append([call(1), call(2)])
        // when
        builder.append([result(3), result(4), call(5), result(6)])
        // then
        #expect(builder.items.count == 3)
        let allCallsUnresolved = builder.items.allSatisfy(\.isRunningTool)
        #expect(allCallsUnresolved)
        // given — a new continuity interval
        builder.breakContinuity()
        // when
        builder.append([call(7), result(8), call(9), result(10)])
        // then — settled IDs can be reused safely within the new interval
        #expect(builder.items.suffix(2).allSatisfy { !$0.isRunningTool })
        let originalCallsUnresolved = builder.items.prefix(3).allSatisfy(\.isRunningTool)
        #expect(originalCallsUnresolved)
    }

    @Test
    func givenScopedOccurrence_whenWindowReplacedOrPrepended_thenIdentityChangesOnlyWithScope() {
        // given
        let memberTask = task("task")
        let item = Timeline.items(from: [projected(7, id: 100, kind: .notice("kept"))])[0]
        func rows(_ scope: String?, items: [TimelineItem]) -> [ConversationTimelineRow] {
            ConversationTimeline.rows(itemMembers: [ConversationItemMember(task: memberTask, items: items, prompt: nil, identityScope: scope)])
        }
        // when
        let original = rows("window-a", items: [item])
        let replaced = rows("window-b", items: [item])
        let prepended = rows("window-a", items: [TimelineItem(id: 99, at: nil, body: .notice("older")), item])
        // then
        #expect(original[0].id != replaced[0].id)
        #expect(original[0].id == prepended[1].id)
        #expect(rows(nil, items: [item])[0].id == "task#100")
    }
}
