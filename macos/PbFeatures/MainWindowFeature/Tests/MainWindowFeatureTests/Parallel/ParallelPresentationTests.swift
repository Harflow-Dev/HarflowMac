import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

extension ParallelVMTests {
    @Test func givenOnlyEnforcementChanges_whenBuildingTaskRenderKeys_thenAllOtherRawTaskFieldsRemainSignificant() {
        // given — include known action/status/time fields and unknown future metadata in the raw
        // task contract; enforcement is the only group-header-only field.
        let base: [String: JSONValue] = [
            "task_id": .string("task"), "started_at": .string("2026-01-01T00:00:00Z"),
            "status": .string("completed"), "taken_over": .bool(true),
            "session_id": .string("session"), "repo_path": .string("/repo"),
            "backend": .string("claude"), "title": .string("Title"),
            "freedom": .string("write_in_repo"), "workflow_role": .string("node"),
            "execution_kind": .string("native_subagent"), "workflow_run_id": .string("run"),
            "workflow_tree_status": .string("completed"), "workflow_tree_settling": .bool(false),
            "suspended_via_root": .bool(false), "future_metadata": .string("kept")
        ]
        var changedEnforcement = base
        changedEnforcement["enforcement"] = .object(["os_enforced": .bool(true)])
        var baseWithEnforcement = base
        baseWithEnforcement["enforcement"] = .object(["network_access": .string("blocked")])
        let first = TaskInfo(.object(baseWithEnforcement))!
        let second = TaskInfo(.object(changedEnforcement))!

        // when / then — only enforcement differs, so the rendering key remains equal.
        #expect(ParallelTaskRenderingKey(first) == ParallelTaskRenderingKey(second))

        // Every other raw field remains observable in equality, including unknown future data.
        for key in base.keys {
            var mutated = baseWithEnforcement
            mutated[key] = .string("changed")
            #expect(ParallelTaskRenderingKey(first) != ParallelTaskRenderingKey(TaskInfo(.object(mutated))!), "(key) must remain significant")
        }
    }

    @Test func givenCurrentMembersWithMixedTerminalStates_whenStatusSummaryIsBuilt_thenEveryMemberIsCountedOnce() {
        // given — the header summary reads the complete current membership, not resident lanes.
        let members = [
            task(id: "running", status: "running"),
            task(id: "done", status: "completed"),
            task(id: "failed", status: "failed"),
            task(id: "timed-out", status: "timed_out"),
            task(id: "cancelled", status: "cancelled"),
            task(id: "unknown", status: "future_status")
        ]

        // when / then
        #expect(ParallelStatusSummary.text(members) == "1 running · 1 done · 2 failed · 1 cancelled")
        #expect(ParallelStatusSummary.text([]) == nil)
        #expect(ParallelStatusSummary.text([task(id: "unknown", status: "future_status")]) == nil)
    }

    @Test func givenACompleteProseOnlyMember_whenParallelPresentationBuilds_thenItShowsOneStepAndNoToolCalls() throws {
        // given
        let memberTask = task(id: "prose", status: "completed")
        let member = ParallelMemberInput(task: memberTask,
                                         items: [PreviewFixtures.textItem("A prose result.", seq: 1)],
                                         prompt: nil, availability: .available)
        let input = ParallelColumnInput(base: basePresentation(for: memberTask), members: [member], events: [], snapshot: nil)

        // when
        let presentation = try ParallelPresentationBuilder.build(input)

        // then
        #expect(presentation.stepCountText == "1 step")
        #expect(presentation.noToolCallsText == "No tool calls recorded")
        #expect(presentation.emptyText == nil)
    }

    @Test func givenAnIncompleteOrUnreadableHistory_whenParallelPresentationBuilds_thenNoToolClaimIsOmitted() throws {
        // given
        let memberTask = task(id: "prose", status: "completed")
        let member = ParallelMemberInput(task: memberTask,
                                         items: [PreviewFixtures.textItem("A prose result.", seq: 1)],
                                         prompt: nil, availability: .available)

        // when / then — a settled member is not enough if older history is still loading or failed.
        for history in [EventHistoryState(isLoading: true), EventHistoryState(error: "not read")] {
            var base = basePresentation(for: memberTask)
            base.history = history
            let input = ParallelColumnInput(base: base, members: [member], events: [], snapshot: nil)
            let presentation = try ParallelPresentationBuilder.build(input)
            #expect(presentation.noToolCallsText == nil)
        }
    }

    @Test func givenACompleteEmptyMember_whenParallelPresentationBuilds_thenEmptyActivityIsProvenToolFree() throws {
        // given
        let memberTask = task(id: "empty", status: "completed")
        let member = ParallelMemberInput(task: memberTask, items: [], prompt: nil, availability: .available)
        let input = ParallelColumnInput(base: basePresentation(for: memberTask), members: [member], events: [], snapshot: nil)

        // when
        let presentation = try ParallelPresentationBuilder.build(input)

        // then — an empty completed log is only labelled after the complete available log proves
        // that it contains no tool calls.
        #expect(presentation.noToolCallsText == "No tool calls recorded")
        #expect(presentation.emptyText == nil)
    }

    @Test func givenACompleteMemberWithAHiddenToolItem_whenParallelPresentationBuilds_thenNoToolClaimIsNotInferredFromVisibleRows() throws {
        // given — compact workflow presentation may hide a managed tool from its visible rows,
        // but the unfiltered member timeline still contains it.
        let memberTask = task(id: "managed", status: "completed")
        let events = try [
            #require(TaskEvent(line: "{\"v\":1,\"seq\":1,\"kind\":\"tool_call\",\"call_id\":\"c1\",\"tool\":\"workflow\",\"category\":\"workflow\"}")),
            #require(TaskEvent(line: "{\"v\":1,\"seq\":2,\"kind\":\"tool_result\",\"call_id\":\"c1\",\"ok\":true}"))
        ]
        let member = ParallelMemberInput(task: memberTask, items: Timeline.items(from: events), prompt: nil, availability: .available)
        let input = ParallelColumnInput(base: basePresentation(for: memberTask), members: [member], events: events, snapshot: nil)

        // when
        let presentation = try ParallelPresentationBuilder.build(input)

        // then
        #expect(presentation.noToolCallsText == nil)
    }

    private func basePresentation(for task: TaskInfo) -> ParallelColumnPresentation {
        ParallelColumnPresentation(id: task.id, task: task, title: task.id, subtitle: task.backend,
                                   isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
                                   start: task.startedAt, memberTaskIDs: [task.id])
    }

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
