import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

extension ParallelVMTests {
    @Test func givenResumeTimeline_whenCancellationAwareConcatenationRuns_thenCanonicalRowsArePreserved() throws {
        let first = task(id: "first", status: "completed", startedAt: Date(timeIntervalSince1970: 1))
        let second = task(id: "second", startedAt: Date(timeIntervalSince1970: 2), parentTaskID: "first")
        let lines = [
            "{\"v\":1,\"seq\":1,\"kind\":\"task_started\",\"prompt\":\"assignment\"}",
            "{\"v\":1,\"seq\":2,\"kind\":\"user_message\",\"text\":\"assignment\",\"source\":\"initial\"}",
            "{\"v\":1,\"seq\":3,\"kind\":\"assistant_text\",\"text\":\"answer\"}"
        ]
        let events = try lines.map { try #require(TaskEvent(line: $0)) }
        let items = Timeline.items(from: events)
        let members = [ConversationItemMember(task: first, items: items, prompt: "assignment"),
                       ConversationItemMember(task: second, items: items, prompt: "assignment")]
        #expect(try ParallelPresentationBuilder.rows(members) == ConversationTimeline.rows(itemMembers: members))
        let empty = [ConversationItemMember(task: first, items: [], prompt: nil),
                     ConversationItemMember(task: second, items: [], prompt: nil)]
        #expect(try ParallelPresentationBuilder.rows(empty) == ConversationTimeline.rows(itemMembers: empty))
    }

    @Test func givenEqualRendering_whenActionClosuresDiffer_thenRenderEqualityStillHolds() {
        let current = task(id: "task", startedAt: Date(timeIntervalSince1970: 1))
        func model(open: @escaping () -> Void) -> ParallelColumnModel {
            ParallelColumnModel(id: "task", task: current, title: "Title", subtitle: "Subtitle", isBusy: false,
                outcomeMessage: nil, showPrompt: false, prompt: nil, rows: [], activityRows: [], liveStep: nil,
                isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: open)
        }
        let first = model(open: {})
        var second = model(open: { _ = Date.now })
        #expect(first.renderValue == second.renderValue)
        second.animatesArrival = true
        #expect(first.renderValue != second.renderValue)
        second.animatesArrival = false
        second.isResident = false
        #expect(first.renderValue != second.renderValue)
        second.isResident = true
        second.memberTaskIDs = ["task", "resumed"]
        #expect(first.renderValue != second.renderValue)
    }
}
