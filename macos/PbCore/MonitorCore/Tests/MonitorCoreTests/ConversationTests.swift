import Foundation
@testable import MonitorCore
import Testing

@Suite
struct ConversationTests {

    // MARK: - Grouping

    @Test
    func givenAChainOfThreeResumes_whenGrouped_thenTheyFormOneConversationOrderedOldestToNewest() {
        // given
        let tasks = [
            task("a", status: "completed", minute: 0),
            task("b", status: "completed", parentTaskID: "a", minute: 1),
            task("c", status: "completed", parentTaskID: "b", minute: 2)
        ]
        // when
        let convs = Lineage.conversations(tasks)
        // then
        #expect(convs.count == 1)
        #expect(convs[0].id == "a")
        #expect(convs[0].first.taskID == "a")
        #expect(convs[0].current.taskID == "c")
        #expect(convs[0].members.map(\.taskID) == ["a", "b", "c"])
    }

    @Test
    func givenATaskWhoseParentIsMissing_whenGrouped_thenItStartsItsOwnConversation() {
        // given — retention removed "a", or it never existed on disk.
        let tasks = [task("b", status: "completed", parentTaskID: "a")]
        // when
        let convs = Lineage.conversations(tasks)
        // then
        #expect(convs.count == 1)
        #expect(convs[0].id == "b")
        #expect(convs[0].members.map(\.taskID) == ["b"])
    }

    @Test
    func givenBranchingResumes_whenGrouped_thenBothBranchesJoinTheSameConversation() {
        // given — A was resumed twice (an older, already-finished member can be resumed again).
        let tasks = [
            task("a", status: "completed", minute: 0),
            task("b", status: "completed", parentTaskID: "a", minute: 1),
            task("c", status: "running", parentTaskID: "a", minute: 2)
        ]
        // when
        let convs = Lineage.conversations(tasks)
        // then
        #expect(convs.count == 1)
        #expect(convs[0].id == "a")
        #expect(convs[0].members.map(\.taskID) == ["a", "b", "c"], "ordered oldest to newest, tie broken by task id")
        #expect(convs[0].current.taskID == "c", "the newest member, not necessarily the last resumed branch by id")
    }

    @Test
    func givenMembersWithDifferentSpawners_whenGrouped_thenSpawnedByNeverDeterminesConversationMembership() {
        // given — b was spawned by a different task entirely; only `parent_task_id` groups members.
        let tasks = [
            task("a", status: "completed", minute: 0),
            task("b", status: "completed", spawnedBy: "other", parentTaskID: "a", minute: 1)
        ]
        // when
        let convs = Lineage.conversations(tasks)
        // then
        #expect(convs.count == 1)
        #expect(convs[0].members.map(\.taskID) == ["a", "b"])
    }

    @Test
    func givenACycleInParentTaskID_whenGrouped_thenItBreaksDeterministicallyAndEveryTaskStillAppears() {
        // given — corrupted data: a <-> b via parent_task_id.
        let tasks = [
            task("a", status: "completed", parentTaskID: "b", minute: 0),
            task("b", status: "completed", parentTaskID: "a", minute: 1)
        ]
        // when
        let convs = Lineage.conversations(tasks)
        // then — every task appears exactly once, across however many conversations resulted.
        let allMembers = convs.flatMap { $0.members.map(\.taskID) }
        #expect(Set(allMembers) == ["a", "b"])
        #expect(allMembers.count == 2)
    }

    @Test
    func givenAnyMemberID_whenResolvingTheConversationContainingIt_thenTheWholeConversationComesBack() {
        // given — Design point 6: any member id resolves the whole conversation.
        let tasks = [
            task("a", status: "completed", minute: 0),
            task("b", status: "completed", parentTaskID: "a", minute: 1)
        ]
        // when / then
        #expect(Lineage.conversation(containing: "b", in: tasks)?.members.map(\.taskID) == ["a", "b"])
        #expect(Lineage.conversation(containing: "a", in: tasks)?.members.map(\.taskID) == ["a", "b"])
        #expect(Lineage.conversation(containing: "missing", in: tasks) == nil)
    }

    @Test
    func givenAnyMemberID_whenNormalisingToTheConversationID_thenItResolvesToTheFirstMember() {
        // given
        let tasks = [task("a", minute: 0), task("b", parentTaskID: "a", minute: 1)]
        // when / then
        #expect(Lineage.conversationID(of: "b", in: tasks) == "a")
        #expect(Lineage.conversationID(of: "a", in: tasks) == "a")
        #expect(Lineage.conversationID(of: "unknown", in: tasks) == "unknown", "an id absent from the listing normalises to itself")
    }

    // MARK: - Sub-task trees attach to the conversation, not to one member

    @Test
    func givenASubTaskOfANonFirstMember_whenSectioned_thenItAttachesUnderTheConversation() {
        // given — "child" was spawned by "b", the SECOND member of conversation(a,b).
        let tasks = [
            task("a", status: "completed", minute: 0),
            task("b", status: "completed", parentTaskID: "a", minute: 1),
            task("child", status: "completed", spawnedBy: "b", minute: 2)
        ]
        // when
        let sections = Lineage.conversationSections(tasks)
        // then
        #expect(sections.recent.map(\.id) == ["a"])
        #expect(sections.recent[0].children.map(\.id) == ["child"])
    }

    @Test
    func givenTheASpawnsXThenXResumesAAsBCycle_whenSectioned_thenTheConversationStaysRootAndXAttachesUnderIt() {
        // given — Review round 1, item 2's worked example: A spawns X (X.spawned_by = A); the
        // process running as X later resumes A's session, producing B (B.parent_task_id = A,
        // B.spawned_by = X). Naively parenting conversation(A,B) on B's own spawner (X) would loop
        // with X's own attachment under conversation(A,B).
        let tasks = [
            task("a", status: "completed", minute: 0),
            task("x", status: "completed", spawnedBy: "a", minute: 1),
            task("b", status: "completed", spawnedBy: "x", parentTaskID: "a", minute: 2)
        ]
        // when
        let sections = Lineage.conversationSections(tasks)
        // then — conversation(a,b) is a root, with x attached as its child; no cycle, every task
        // appears exactly once.
        #expect(sections.recent.map(\.id) == ["a"])
        #expect(sections.recent[0].conversation.members.map(\.taskID) == ["a", "b"])
        #expect(sections.recent[0].children.map(\.id) == ["x"])
        #expect(sections.recent[0].children[0].children.isEmpty)
    }

    // MARK: - Placement: descendant-aware Running

    @Test
    func givenATerminalCurrentMemberWithARunningDescendant_whenSectioned_thenTheConversationStaysInRunning() {
        // given
        let tasks = [
            task("a", status: "completed", minute: 0),
            task("b", status: "completed", parentTaskID: "a", minute: 1),
            task("child", status: "running", spawnedBy: "b", minute: 2)
        ]
        // when
        let sections = Lineage.conversationSections(tasks)
        // then
        #expect(sections.running.map(\.id) == ["a"])
        #expect(sections.recent.isEmpty)
    }

    @Test
    func givenAFinishedConversationWithAStillRunningGroupedChild_whenSectioned_thenItStaysInRunningAndTheChildNestsUnderIt() {
        // given — Codex review round 1, finding 1: the pre-piece-7 task-level tree never filtered
        // `parentMap`/`childIDs` by `group` at all (only a ROOT task's own placement checked it —
        // `git show HEAD:.../Lineage.swift`'s `sections(_:matches:)`), so a grouped task spawned by
        // an UNGROUPED conversation still nests under it, and a running grouped descendant keeps a
        // finished conversation in Running exactly as before.
        let tasks = [
            task("a", status: "completed", minute: 0),
            task("x", status: "running", spawnedBy: "a", group: "fanout", minute: 1)
        ]
        // when
        let sections = Lineage.conversationSections(tasks)
        // then
        #expect(sections.running.map(\.id) == ["a"])
        #expect(sections.recent.isEmpty)
        #expect(sections.running[0].children.map(\.id) == ["x"])
    }

    @Test
    func givenAGroupStartedFromInsideARunningConversation_whenSectioned_thenBothGroupMembersNestUnderIt() {
        // given — the conversation-level analogue of `LineageTests`'s own
        // `givenAGroupStartedFromInsideARunningTask_whenSectioned_thenItIsStillAParallelRun`: "lead"
        // spawns two grouped members, which must nest under "lead" here exactly as `TaskNode` nested
        // them before piece 7 (Parallel's OWN listing, unaffected, still shows them as a group too).
        let tasks = [
            task("lead", status: "running", minute: 0),
            task("g1", status: "running", spawnedBy: "lead", group: "fanout", minute: 1),
            task("g2", status: "completed", spawnedBy: "lead", group: "fanout", minute: 2)
        ]
        // when
        let sections = Lineage.conversationSections(tasks)
        // then
        #expect(sections.running.map(\.id) == ["lead"])
        #expect(sections.running[0].children.map(\.id) == ["g1", "g2"])
    }

    @Test
    func givenAGroupAlongsideAnUnrelatedResumeChain_whenSectioned_thenParallelStaysTaskLevelAndUnaffected() {
        // given — Review round 1, item 3: conversations apply only to the Running/Recent tree, so a
        // Parallel group's own members/sub-tasks must read exactly as `Lineage.sections(_:).parallel`
        // computes them today, with a wholly separate resume chain alongside it.
        let tasks = [
            task("r1", status: "completed", group: "plan review", minute: 0),
            task("r2", status: "completed", group: "plan review", minute: 1),
            task("r2-sub", status: "completed", spawnedBy: "r2", group: "plan review", minute: 2),
            task("solo-a", status: "completed", minute: 3),
            task("solo-b", status: "completed", parentTaskID: "solo-a", minute: 4)
        ]
        // when
        let taskSections = Lineage.sections(tasks)
        let convSections = Lineage.conversationSections(tasks)
        // then — Parallel is unaffected.
        #expect(taskSections.parallel.count == 1)
        #expect(taskSections.parallel[0].members.map(\.id) == ["r1", "r2"])
        #expect(taskSections.parallel[0].members[1].children.map(\.id) == ["r2-sub"])
        // and — the unrelated resume chain shows as one conversation, and the group's own tasks
        // never leak into Running/Recent.
        #expect(convSections.recent.map(\.id) == ["solo-a"])
        #expect(convSections.recent[0].conversation.current.taskID == "solo-b")
        let convIDs = convSections.running.map(\.id) + convSections.recent.map(\.id)
        #expect(!convIDs.contains("r1") && !convIDs.contains("r2") && !convIDs.contains("r2-sub"))
    }

    // MARK: - Ancestors / children (sidebar collapse & reveal)

    @Test
    func givenAConversationAttachedUnderAnotherConversation_whenAskingForAncestors_thenTheChainComesBackRootFirst() {
        // given
        let tasks = [
            task("root", status: "completed", minute: 0),
            task("mid", status: "completed", spawnedBy: "root", minute: 1),
            task("mid-b", status: "completed", parentTaskID: "mid", minute: 2),
            task("leaf", status: "completed", spawnedBy: "mid-b", minute: 3)
        ]
        // when / then — "mid"'s own resume ("mid-b") is still where "leaf" attaches, since "leaf" was
        // spawned by a non-first member of conversation(mid, mid-b).
        #expect(Lineage.conversationAncestors(of: "leaf", in: tasks).map(\.id) == ["root", "mid"])
        #expect(Lineage.conversationChildren(of: "mid", in: tasks).map(\.id) == ["leaf"])
    }

    // MARK: - Menu-bar / recent: one entry per conversation

    @Test
    func givenAResumedRootTask_whenSectioned_thenRecentShowsOneConversationNotTwoRows() {
        // given — before piece 7, "a" and "b" would each show up as their own recent root.
        let tasks = [task("a", status: "completed", minute: 0), task("b", status: "completed", parentTaskID: "a", minute: 1)]
        // when
        let sections = Lineage.conversationSections(tasks)
        // then
        #expect(sections.recent.count == 1)
        #expect(sections.recent[0].conversation.current.taskID == "b")
    }

    // MARK: - Cancel scope (Review round 2 — matches tasks.py's cascade exactly)

    @Test
    func givenASpawnedByChain_whenComputingCancelScope_thenEveryDescendantIsIncluded() {
        // given
        let tasks = [
            task("root", status: "running"),
            task("child", status: "running", spawnedBy: "root"),
            task("grandchild", status: "running", spawnedBy: "child")
        ]
        // when / then
        #expect(Lineage.cancelScope(of: "root", in: tasks) == ["root", "child", "grandchild"])
    }

    @Test
    func givenARootOnlyLinkedDescendant_whenComputingCancelScope_thenItIsIncludedEvenWithNoSpawnedByPath() {
        // given — lineage detection is best-effort: this task only ever recorded its `root_task_id`,
        // with no `spawned_by` edge reaching it at all.
        let tasks = [
            task("root", status: "running"),
            task("orphaned-but-rooted", status: "running", rootTaskID: "root")
        ]
        // when / then
        #expect(Lineage.cancelScope(of: "root", in: tasks) == ["root", "orphaned-but-rooted"])
    }

    @Test
    func givenAnEarlierTurnsChildNotReachableEitherWay_whenComputingCancelScope_thenItIsExcluded() {
        // given — "sibling-child" was spawned by an EARLIER turn ("a"), and the cancel targets the
        // CURRENT turn ("b"): neither `spawned_by` nor `root_task_id` reaches it from "b".
        let tasks = [
            task("a", status: "completed"),
            task("b", status: "running", parentTaskID: "a"),
            task("sibling-child", status: "running", spawnedBy: "a")
        ]
        // when / then
        #expect(Lineage.cancelScope(of: "b", in: tasks) == ["b"])
    }

    // MARK: - EditedFiles across turns

    @Test
    func givenTheSamePathEditedInTwoTurns_whenMergedAcrossMembers_thenTheLaterTurnsStatusWins() {
        // given — each member's own call ids restart at "c1"; pairing must stay scoped per member.
        let turn1: [TaskEvent] = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"tool_call","call_id":"c1","tool":"Edit","category":"edit","input_preview":"","path":"/repo/a.swift"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"tool_result","call_id":"c1","ok":false,"output_tail":""}"#)!
        ]
        let turn2: [TaskEvent] = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"tool_call","call_id":"c1","tool":"Edit","category":"edit","input_preview":"","path":"/repo/a.swift"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"tool_result","call_id":"c1","ok":true,"output_tail":""}"#)!
        ]
        // when
        let merged = EditedFiles.build(fromMembers: [turn1, turn2], repoPath: "/repo")
        // then
        #expect(merged == [EditedFile(path: "a.swift", status: .edited)])
    }

    // MARK: - ConversationTimeline: turn separators and per-turn live state

    @Test
    func givenTwoMembers_whenBuildingRows_thenASeparatorPrecedesTheSecondTurnWithItsOwnPromptAndTime() {
        // given
        let firstEvents = [TaskEvent(line: #"{"v":1,"seq":0,"kind":"task_started","prompt":"fix the bug"}"#)!]
        let secondEvents = [TaskEvent(line: #"{"v":1,"seq":0,"kind":"task_started","prompt":"also add a test"}"#)!]
        let members = [
            ConversationMember(task: task("a", status: "completed", minute: 0), events: firstEvents),
            ConversationMember(task: task("b", status: "completed", parentTaskID: "a", minute: 1), events: secondEvents)
        ]
        // when
        let rows = ConversationTimeline.rows(members: members)
        // then
        let separators = rows.compactMap { row -> String? in
            if case .separator(let text) = row.kind { return text }
            return nil
        }
        #expect(separators == ["also add a test"])
        #expect(rows.first?.taskID == "a", "the first member's own turn has no separator ahead of it")
    }

    @Test
    func givenTwoMembers_whenBuildingRows_thenOnlyTheFirstTurnKeepsItsStartedRow() {
        // given
        let firstEvents = [TaskEvent(line: #"{"v":1,"seq":0,"kind":"task_started","prompt":"fix the bug"}"#)!]
        let secondEvents = [TaskEvent(line: #"{"v":1,"seq":0,"kind":"task_started","prompt":"also add a test"}"#)!]
        let members = [
            ConversationMember(task: task("a", status: "completed", minute: 0), events: firstEvents),
            ConversationMember(task: task("b", status: "completed", parentTaskID: "a", minute: 1), events: secondEvents)
        ]
        // when
        let rows = ConversationTimeline.rows(members: members)
        // then
        let startedTaskIDs = rows.compactMap { row -> String? in
            if case .item(let item) = row.kind, case .started = item.body { return row.taskID }
            return nil
        }
        #expect(startedTaskIDs == ["a"])
    }

    @Test
    func givenDuplicateSeqAndCallIDsAcrossMembers_whenBuildingRows_thenEveryRowGetsAGloballyUniqueID() {
        // given — both members' own logs restart at seq 0/call "c1".
        let events: [TaskEvent] = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"tool_call","call_id":"c1","tool":"Bash","category":"shell","input_preview":"x","command":"x"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"tool_result","call_id":"c1","ok":true,"output_tail":""}"#)!
        ]
        let members = [
            ConversationMember(task: task("a", status: "completed", minute: 0), events: events),
            ConversationMember(task: task("b", status: "completed", parentTaskID: "a", minute: 1), events: events)
        ]
        // when
        let rows = ConversationTimeline.rows(members: members)
        // then
        #expect(Set(rows.map(\.id)).count == rows.count, "no two rows collide despite identical per-task seq/call ids")
    }

    @Test
    func givenAnUnresolvedToolInAnOldTerminalTurnWhileTheNewTurnRuns_whenBuildingRows_thenOnlyTheNewTurnIsLive() {
        // given — the OLDER member's own tool call never got a result (e.g. it was cancelled), while
        // a NEWER member (the current turn) is still running its own tool.
        let oldEvents: [TaskEvent] = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"tool_call","call_id":"c1","tool":"Bash","category":"shell","input_preview":"x","command":"x"}"#)!
        ]
        let newEvents: [TaskEvent] = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"tool_call","call_id":"c1","tool":"Bash","category":"shell","input_preview":"y","command":"y"}"#)!
        ]
        let members = [
            ConversationMember(task: task("a", status: "cancelled", minute: 0), events: oldEvents),
            ConversationMember(task: task("b", status: "running", parentTaskID: "a", minute: 1), events: newEvents)
        ]
        // when
        let rows = ConversationTimeline.rows(members: members)
        // then
        let oldRow = rows.first { $0.taskID == "a" }
        let newRow = rows.first { row in
            guard row.taskID == "b", case .item = row.kind else { return false }
            return true
        }
        #expect(oldRow?.live == false, "an old, terminal turn's unresolved tool never shows a spinner")
        #expect(newRow?.live == true, "the current, running turn's unresolved tool does")
    }

    @Test
    func givenALiveInputInitialMessageDuplicatingTheSeparator_whenBuildingRows_thenItIsDroppedButOtherMessagesStay() {
        // given — a live-input follow-up: its own `user_message(source: "initial")` duplicates the
        // separator; an "injected" message mid-turn must still show.
        let events: [TaskEvent] = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"task_started","prompt":"follow up"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"user_message","text":"follow up","source":"initial"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":2,"kind":"user_message","text":"one more thing","source":"injected"}"#)!
        ]
        let members = [
            ConversationMember(task: task("a", status: "completed", minute: 0), events: []),
            ConversationMember(task: task("b", status: "running", parentTaskID: "a", minute: 1), events: events)
        ]
        // when
        let rows = ConversationTimeline.rows(members: members)
        // then
        let messages = rows.compactMap { row -> (text: String, source: String?)? in
            if case .item(let item) = row.kind, case .message(let text, let source) = item.body { return (text, source) }
            return nil
        }
        #expect(messages.map(\.text) == ["one more thing"], "the duplicate initial prompt is dropped, the injected message stays")
    }

    // MARK: - Deterministic survivor rule (Codex review round 1, finding 3)

    @Test
    func givenBranchingSurvivorsAfterAPrune_whenPickingTheOldestSurvivor_thenItIsDeterministicByStartedAtThenID() {
        // given — A was resumed twice, to "b" and "c" (branching); A itself is later pruned by
        // retention. "b" is the older of the two survivors.
        let tasks = [
            task("b", status: "completed", minute: 1),
            task("c", status: "running", minute: 2)
        ]
        // when / then — the candidate SET's own iteration order must never matter.
        #expect(Lineage.oldestSurvivor(among: ["b", "c"], in: tasks) == "b")
        #expect(Lineage.oldestSurvivor(among: ["c", "b"], in: tasks) == "b")
    }

    @Test
    func givenATieOnStartedAt_whenPickingTheOldestSurvivor_thenTheLowerTaskIDWins() {
        // given
        let tasks = [task("b", status: "completed", minute: 1), task("a", status: "completed", minute: 1)]
        // when / then
        #expect(Lineage.oldestSurvivor(among: ["b", "a"], in: tasks) == "a")
    }

    @Test
    func givenNoCandidateIsPresent_whenPickingTheOldestSurvivor_thenNilComesBack() {
        // given
        let tasks = [task("z", status: "completed")]
        // when / then
        #expect(Lineage.oldestSurvivor(among: ["b", "c"], in: tasks) == nil)
        #expect(Lineage.oldestSurvivor(among: [], in: tasks) == nil)
    }
}
