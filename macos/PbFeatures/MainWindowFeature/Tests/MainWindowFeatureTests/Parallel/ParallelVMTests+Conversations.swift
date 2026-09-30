import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

/// Monitor piece 13: a column is one agent conversation (a resume chain), not one task — split out
/// of `ParallelVMTests.swift` to keep that file under the length limit. Reuses its `makeSUT()`/
/// `task(...)`/`SUT` (no Mockable FIFO conflict here, unlike `TaskDetailVMTests+Conversation.swift`'s
/// own reason for building a fresh harness: every stub `makeSUT()` registers is a wildcard
/// `.any` `willProduce` reading from a box, not a per-value stub a later registration would race).
@MainActor
extension ParallelVMTests {

    @Test func givenTwoConversationsOfThreeTurnsEach_whenTasksPublish_thenTheyBecomeTwoColumnsWithTurnSeparators() async {
        // given — an orchestrator that resumed each of its 2 agents twice: 6 tasks, but a column
        // per AGENT (conversation), never per resume turn.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let leasesBox = harness.leasesBox
        let start = Date.now.addingTimeInterval(-300)
        let agentATurn1 = task(id: "a1", status: "completed", startedAt: start)
        let agentATurn2 = task(id: "a2", status: "completed", startedAt: start.addingTimeInterval(100), parentTaskID: "a1")
        let agentATurn3 = task(id: "a3", status: "running", startedAt: start.addingTimeInterval(200), parentTaskID: "a2")
        let agentBTurn1 = task(id: "b1", status: "completed", startedAt: start)
        let agentBTurn2 = task(id: "b2", status: "completed", startedAt: start.addingTimeInterval(100), parentTaskID: "b1")
        let agentBTurn3 = task(id: "b3", status: "completed", startedAt: start.addingTimeInterval(200), parentTaskID: "b2")
        let members = [agentATurn1, agentATurn2, agentATurn3, agentBTurn1, agentBTurn2, agentBTurn3]
        for member in members { tasksBox.value[member.taskID] = member }
        sut.didAppear()

        // when
        tasksSubject.send(members)

        // then — two columns, one per agent conversation, never six
        await waitUntil { sut.columns.count == 2 }
        #expect(sut.headerSubtitle.hasPrefix("2 agents"))
        #expect(
            Set(leasesBox.value.keys) == ["a1", "a2", "a3", "b1", "b2", "b3"],
            "a lease is held for every turn of every conversation, not just its current one"
        )

        // then — the still-running conversation sorts first (`Lineage.parallelColumnOrder`), its
        // column's `task` is the CURRENT (newest) member, and its timeline carries a separator ahead
        // of each of its 2 follow-ups
        let runningColumn = sut.columns.first
        #expect(runningColumn?.task.taskID == "a3")
        #expect(runningColumn?.start == agentATurn1.startedAt, "rows time from the first turn, not the current one")
        let separatorCount = runningColumn?.rows.filter { if case .separator = $0.kind { return true }; return false }.count
        #expect(separatorCount == 2)
        #expect(runningColumn?.subtitle.hasSuffix("· 3 turns") == true, "the subtitle counts the conversation's turns")
        #expect(runningColumn?.subtitle.contains("session") == false, "session ids stay off the column header")
        #expect(runningColumn?.activityRows.count == runningColumn?.rows.count, "no tool calls to fold, so one activity row per row")

        // when — "Open task" on the running column
        runningColumn?.onTapOpenTask()

        // then — it selects the conversation's CURRENT member, never its first
        verify(harness.routing).selectTask(.value("a3")).called(1)
    }

    @Test func givenAThreeTurnConversation_whenDidDisappearIsCalled_thenEveryTurnsLeaseIsReleased() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let tasksBox = harness.tasksBox
        let releasedBox = harness.releasedBox
        let start = Date.now.addingTimeInterval(-300)
        let agentATurn1 = task(id: "a1", status: "completed", startedAt: start)
        let agentATurn2 = task(id: "a2", status: "completed", startedAt: start.addingTimeInterval(100), parentTaskID: "a1")
        let agentATurn3 = task(id: "a3", status: "running", startedAt: start.addingTimeInterval(200), parentTaskID: "a2")
        let members = [agentATurn1, agentATurn2, agentATurn3]
        for member in members { tasksBox.value[member.taskID] = member }
        sut.didAppear()
        tasksSubject.send(members)
        await waitUntil { sut.columns.count == 1 }

        // when
        sut.didDisappear()

        // then — every member's lease is released, not just the current turn's
        #expect(releasedBox.value == ["a1", "a2", "a3"])
    }
}
