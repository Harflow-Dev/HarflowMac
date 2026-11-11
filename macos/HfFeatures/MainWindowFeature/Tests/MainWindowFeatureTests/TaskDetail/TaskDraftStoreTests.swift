import Foundation
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskDraftStoreTests

/// The store's retention rules on hand-built listings: which cell a conversation shows, how it survives pruning,
/// splits and joins, and that nothing is merged, evicted or deleted behind the user's back.
@MainActor
@Suite struct TaskDraftStoreTests {
    @MainActor private final class Clock {
        var now = Date(timeIntervalSince1970: 1_000)
        func tick() { now = now.addingTimeInterval(1) }
    }

    @MainActor private final class Rig {
        let clock = Clock()
        let store: TaskDraftStore
        private(set) var tasks: [TaskInfo]
        var partition: TaskDraftPartition { TaskDraftPartition(tasks: tasks) }

        init(_ tasks: [TaskInfo]) {
            self.tasks = tasks
            let clock = clock
            self.store = TaskDraftStore(clock: { clock.now })
        }

        /// A mount the way the coordinator's builder makes one: key and members from the listing, `owner` as the
        /// view model's live current task.
        func mount(_ id: String, owner: String? = nil) -> TaskDraftMount {
            let partition = partition
            let key = partition.keyOfMember[id] ?? id
            let members = partition.membersOfKey[key] ?? [id]
            return store.makeMount(key: key, members: members, partition: partition) { owner ?? id }
        }

        func type(_ text: String, in mount: TaskDraftMount) {
            clock.tick()
            mount.text.wrappedValue = text
        }

        func list(_ tasks: [TaskInfo]) {
            self.tasks = tasks
            store.reconcile(partition: TaskDraftPartition(tasks: tasks))
        }
    }

    private func task(_ id: String, parent: String? = nil, spawnedBy: String? = nil, minute: Int) -> TaskInfo {
        var raw: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string("claude"), "status": .string("completed"),
            "started_at": .string(String(format: "2026-09-30T10:%02d:00Z", minute))
        ]
        if let parent { raw["parent_task_id"] = .string(parent) }
        if let spawnedBy { raw["spawned_by"] = .string(spawnedBy) }
        return TaskInfo(.object(raw))!
    }

    // MARK: - Storage

    @Test func givenAFreshMount_whenNothingIsTyped_thenNothingIsStored() {
        // given
        let rig = Rig([task("a", minute: 1)])

        // when
        let mount = rig.mount("a")
        mount.text.wrappedValue = ""

        // then
        #expect(rig.store.storedCount == 0)
        #expect(!rig.store.isStored(mount.cell))
    }

    @Test func givenATypedDraft_whenItBecomesEmpty_thenTheCellIsRemoved() {
        // given
        let rig = Rig([task("a", minute: 1)])
        let mount = rig.mount("a")
        rig.type("hello", in: mount)
        #expect(rig.store.storedCount == 1)

        // when
        rig.type("", in: mount)

        // then
        #expect(rig.store.storedCount == 0)
        #expect(rig.mount("a").cell.text.isEmpty)
    }

    @Test func givenAClearedDraft_whenRetypedAndRemounted_thenTheNewTextIsKept() {
        // given
        let rig = Rig([task("a", minute: 1)])
        let mount = rig.mount("a")
        rig.type("first", in: mount)
        rig.type("", in: mount)

        // when
        rig.type("second", in: mount)

        // then
        #expect(rig.mount("a").text.wrappedValue == "second")
    }

    @Test func givenAMultilineDraftWithEdgeWhitespace_whenRemounted_thenItsExactBytesAreKept() {
        // given
        let rig = Rig([task("a", minute: 1)])
        let draft = "  \n\tline two with trailing space \n\n "
        rig.type(draft, in: rig.mount("a"))

        // when
        let restored = rig.mount("a").text.wrappedValue

        // then
        #expect(Array(restored.utf8) == Array(draft.utf8))
    }

    @Test func givenAWhitespaceOnlyDraft_whenRemounted_thenItIsStoredAndKeptExactly() {
        // given
        let rig = Rig([task("a", minute: 1)])

        // when
        rig.type("  \n ", in: rig.mount("a"))

        // then
        #expect(rig.mount("a").text.wrappedValue == "  \n ")
        #expect(rig.store.storedCount == 1)
    }

    // MARK: - Resolution

    @Test func givenADraft_whenTheSameConversationIsMountedAgain_thenItIsTheSameCell() {
        // given
        let rig = Rig([task("a", minute: 1), task("b", parent: "a", minute: 2)])
        let first = rig.mount("a")
        rig.type("draft", in: first)

        // when
        let viaFirstMember = rig.mount("a")
        let viaLaterMember = rig.mount("b")

        // then
        #expect(viaFirstMember.cell === first.cell)
        #expect(viaLaterMember.cell === first.cell)
    }

    @Test func givenADraft_whenAnotherConversationIsMounted_thenItShowsItsOwnEmptyComposer() {
        // given
        let rig = Rig([task("a", minute: 1), task("z", minute: 3)])
        rig.type("draft", in: rig.mount("a"))

        // when
        let other = rig.mount("z")

        // then
        #expect(other.cell.text.isEmpty)
        #expect(!rig.store.isStored(other.cell))
    }

    @Test func givenSpawnedByLinksOnly_whenMounted_thenTheTasksNeverShareADraft() {
        // given
        let rig = Rig([task("a", minute: 1), task("x", spawnedBy: "a", minute: 2)])
        rig.type("draft for a", in: rig.mount("a"))

        // when / then
        #expect(rig.mount("x").cell.text.isEmpty)
        rig.list([task("x", spawnedBy: "a", minute: 2)])
        #expect(rig.mount("x").cell.text.isEmpty)
    }

    // MARK: - Rekey

    @Test func givenAConversation_whenItsEarliestMemberIsPruned_thenTheSameDraftFollowsTheNewKey() {
        // given
        let taskA = task("a", minute: 1)
        let taskB = task("b", parent: "a", minute: 2)
        let rig = Rig([taskA, taskB])
        let typed = rig.mount("a")
        rig.type("draft", in: typed)

        // when
        rig.list([taskB])
        let rekeyed = rig.mount("b")

        // then
        #expect(rekeyed.cell === typed.cell)
        #expect(rekeyed.text.wrappedValue == "draft")
    }

    @Test func givenAContinuationAppearsWhileClosed_whenTheEarliestMemberIsThenPruned_thenTheDraftStillFollows() {
        // given
        let taskA = task("a", minute: 1)
        let rig = Rig([taskA])
        let typed = rig.mount("a")
        rig.type("draft", in: typed)
        let taskB = task("b", parent: "a", minute: 2)

        // when
        rig.list([taskA, taskB])
        rig.list([taskB])

        // then
        #expect(rig.mount("b").cell === typed.cell)
    }

    @Test func givenAMountedComposer_whenItsEarliestMemberIsPruned_thenItKeepsTypingIntoTheSameCell() {
        // given
        let taskA = task("a", minute: 1)
        let taskB = task("b", parent: "a", minute: 2)
        let rig = Rig([taskA, taskB])
        let mounted = rig.mount("a")
        rig.type("one", in: mounted)
        let cell = mounted.cell

        // when
        rig.list([taskB])
        rig.type("one two", in: mounted)

        // then
        #expect(mounted.cell === cell)
        #expect(mounted.testingKey == "b")
        #expect(rig.mount("b").cell === cell)
        #expect(rig.mount("b").text.wrappedValue == "one two")
    }

    // MARK: - Splits

    @Test func givenABranchSplit_whenTheOwnerBranchSurvives_thenOnlyThatBranchGetsTheDraft() {
        // given
        let taskA = task("a", minute: 1)
        let taskB = task("b", parent: "a", minute: 2)
        let taskC = task("c", parent: "a", minute: 3)
        let rig = Rig([taskA, taskB, taskC])
        let typed = rig.mount("a", owner: "c")
        rig.type("draft", in: typed)
        let homeCell = typed.cell

        // when
        rig.list([taskB, taskC])

        // then
        #expect(rig.mount("c").cell === homeCell)
        #expect(rig.mount("b").cell.text.isEmpty)
    }

    @Test func givenABranchSplit_whenTheOwnerIsPrunedToo_thenTheBranchWithTheOldestSurvivorGetsTheDraft() {
        // given
        let taskA = task("a", minute: 1)
        let taskB = task("b", parent: "a", minute: 2)
        let taskC = task("c", parent: "a", minute: 3)
        let rig = Rig([taskA, taskB, taskC])
        let typed = rig.mount("a", owner: "a")
        rig.type("draft", in: typed)

        // when
        rig.list([taskB, taskC])

        // then
        #expect(rig.mount("b").cell === typed.cell)
        #expect(rig.mount("c").cell.text.isEmpty)
        #expect(rig.store.storedCount == 1)
    }

    // MARK: - Joins

    private func joinRig() -> (rig: Rig, first: TaskDraftMount, second: TaskDraftMount) {
        let taskB = task("b", parent: "a", minute: 2)
        let taskC = task("c", parent: "a", minute: 3)
        let rig = Rig([taskB, taskC])
        let mountB = rig.mount("b")
        rig.type("draft in b", in: mountB)
        let mountC = rig.mount("c")
        rig.type("draft in c", in: mountC)
        return (rig, mountB, mountC)
    }

    @Test func givenTwoConversationsWithDrafts_whenTheyJoin_thenTheMostRecentIsShownAndTheOtherIsKeptShadowed() {
        // given
        let (rig, mountB, mountC) = joinRig()
        let loser = mountB.cell
        let winner = mountC.cell
        let joined = [task("a", minute: 1), task("b", parent: "a", minute: 2), task("c", parent: "a", minute: 3)]

        // when
        rig.list(joined)
        let shown = rig.mount("a")

        // then
        #expect(shown.cell === winner)
        #expect(shown.text.wrappedValue == "draft in c")
        #expect(rig.store.isShadowed(loser))
        #expect(loser.text == "draft in b")
        #expect(rig.store.storedCount == 2)
    }

    @Test func givenAJoin_whenTheMountedLoserIsReconciled_thenItsComposerRebindsToTheWinnerWithoutMerging() {
        // given
        let (rig, mountB, mountC) = joinRig()

        // when
        rig.list([task("a", minute: 1), task("b", parent: "a", minute: 2), task("c", parent: "a", minute: 3)])

        // then
        #expect(mountB.cell === mountC.cell)
        #expect(mountB.text.wrappedValue == "draft in c")
    }

    @Test func givenAJoinWithOneOwnerOutsideTheMembers_whenReconciled_thenTheOwnedDraftWinsOverTheMoreRecent() {
        // given
        let taskB = task("b", parent: "a", minute: 2)
        let taskC = task("c", parent: "a", minute: 3)
        let rig = Rig([taskB, taskC])
        let owned = rig.mount("b")
        rig.type("owned", in: owned)
        let foreign = rig.mount("c", owner: "gone")
        rig.type("foreign but newer", in: foreign)
        let foreignCell = foreign.cell

        // when
        rig.list([task("a", minute: 1), taskB, taskC])

        // then
        #expect(rig.mount("a").cell === owned.cell)
        #expect(rig.store.isShadowed(foreignCell))
    }

    @Test func givenAJoinWinnerThatIsSent_whenRebuiltAndThenSplitAgain_thenTheLoserNeverAppears() {
        // given
        let (rig, mountB, mountC) = joinRig()
        let loser = mountB.cell
        let winner = mountC.cell
        rig.list([task("a", minute: 1), task("b", parent: "a", minute: 2), task("c", parent: "a", minute: 3)])
        let shown = rig.mount("a")

        // when — the winner is sent (cleared), then the view is rebuilt, then the conversation splits again.
        rig.type("", in: shown)
        let afterSend = rig.mount("a")
        rig.list([task("b", parent: "a", minute: 2), task("c", parent: "a", minute: 3)])

        // then
        #expect(afterSend.cell.text.isEmpty)
        #expect(rig.mount("b").cell.text.isEmpty)
        #expect(rig.mount("c").cell.text.isEmpty)
        #expect(rig.store.isShadowed(loser))
        #expect(loser.text == "draft in b")
        #expect(!rig.store.isStored(winner))
        #expect(rig.store.storedCount == 1)
    }

    @Test func givenAnActiveDraftBeforeAJoin_whenAnotherConversationJoinsWithAnOlderDraft_thenTheNewestWinsAfterReconcile() {
        // given
        let taskB = task("b", parent: "a", minute: 2)
        let taskC = task("c", parent: "a", minute: 3)
        let rig = Rig([taskB, taskC])
        let older = rig.mount("c")
        rig.type("older", in: older)
        let olderCell = older.cell
        let newer = rig.mount("b")
        rig.type("newer", in: newer)
        let newerCell = newer.cell

        // when
        rig.list([task("a", minute: 1), taskB, taskC])

        // then
        #expect(rig.mount("a").cell === newerCell)
        #expect(rig.store.isShadowed(olderCell))
    }

    // MARK: - Unattached drafts

    @Test func givenADraft_whenEveryKnownMemberIsPrunedAtOnce_thenItStaysStoredButAttachesToNothing() {
        // given
        let rig = Rig([task("a", minute: 1), task("b", parent: "a", minute: 2)])
        let typed = rig.mount("a")
        rig.type("draft", in: typed)

        // when
        rig.list([task("z", minute: 5)])

        // then
        #expect(rig.store.storedCount == 1)
        #expect(rig.store.isStored(typed.cell))
        #expect(rig.mount("z").cell.text.isEmpty)
    }

    @Test func givenNoStoredDraftAndNoMount_whenAskedIfItIsIdle_thenTheStoreIsIdle() {
        // given / when
        let rig = Rig([task("a", minute: 1)])

        // then
        #expect(rig.store.isIdle)
        let mount = rig.mount("a")
        #expect(!rig.store.isIdle)
        withExtendedLifetime(mount) {}
    }

    // MARK: - Mounted splits

    private func splitTasks() -> [TaskInfo] {
        [task("a", minute: 1), task("b", parent: "a", minute: 2), task("c", parent: "a", minute: 3)]
    }

    @Test func givenAMountedSplit_whenTheHomeIsAnotherBranch_thenTheMountGetsAnEmptyCellAndNeverTouchesTheHomeDraft() {
        // given
        let rig = Rig(splitTasks())
        let mounted = rig.mount("a", owner: "c")
        rig.type("draft for c", in: mounted)
        let homeCell = mounted.cell

        // when — a is pruned; the mounted view follows b, but the draft is homed on c.
        rig.list([task("b", parent: "a", minute: 2), task("c", parent: "a", minute: 3)])

        // then
        #expect(mounted.cell !== homeCell)
        #expect(mounted.cell.text.isEmpty)
        rig.type("typed in b", in: mounted)
        #expect(homeCell.text == "draft for c")
        rig.type("", in: mounted)
        #expect(homeCell.text == "draft for c")
        #expect(rig.store.isStored(homeCell))
        #expect(rig.mount("c").cell === homeCell)
        #expect(rig.mount("b").cell.text.isEmpty)
    }

    @Test func givenASplitThenAJoinThatShadowsTheMountedCell_whenReconciled_thenTheMountRebindsAndTheHiddenTextIsRetained() {
        // given
        let rig = Rig(splitTasks())
        let mounted = rig.mount("a", owner: "c")
        rig.type("draft for c", in: mounted)
        let homeCell = mounted.cell
        let remaining = [task("b", parent: "a", minute: 2), task("c", parent: "a", minute: 3)]
        rig.list(remaining)
        rig.type("mine in b", in: mounted)
        let mineCell = mounted.cell
        rig.type("newer for c", in: rig.mount("c"))

        // when
        rig.list(splitTasks())

        // then
        #expect(rig.store.isShadowed(mineCell))
        #expect(mineCell.text == "mine in b")
        #expect(mounted.cell === homeCell)
        #expect(mounted.text.wrappedValue == "newer for c")
        #expect(mounted.cell !== mineCell)
    }

    @Test func givenSuccessiveSplitsAndPrunes_whenAMountFollowsSurvivors_thenItNeverAccumulatesOrShowsAnotherBranchsDraft() {
        // given
        let all = [
            task("a", minute: 1), task("b", parent: "a", minute: 2), task("c", parent: "a", minute: 3),
            task("d", parent: "b", minute: 4), task("e", parent: "b", minute: 5)
        ]
        let rig = Rig(all)
        let follower = rig.mount("a")
        rig.list(all)
        rig.list(Array(all.dropFirst()))
        rig.type("draft in c", in: rig.mount("c"))
        let cCell = rig.mount("c").cell
        #expect(follower.testingMembers == ["b", "d", "e"])

        // when — the first split branch b is pruned, splitting d and e.
        rig.list([all[2], all[3], all[4]])
        rig.type("draft in e", in: rig.mount("e"))
        let eCell = rig.mount("e").cell

        // then
        #expect(follower.testingKey == "d")
        #expect(follower.testingMembers == ["d"])
        #expect(follower.cell !== cCell && follower.cell !== eCell)
        #expect(follower.cell.text.isEmpty)
        #expect(rig.mount("c").cell === cCell)
        #expect(rig.mount("e").cell === eCell)
    }

    @Test func givenAStaleActiveCell_whenAnotherCellIsFirstStored_thenItBecomesTheActiveOne() {
        // given
        let rig = Rig([task("a", minute: 1)])
        let first = rig.mount("a")
        rig.type("first", in: first)
        let firstCell = first.cell
        rig.type("", in: first)

        // when
        let second = rig.mount("a")
        rig.type("second", in: second)

        // then
        #expect(rig.mount("a").cell === second.cell)
        #expect(rig.mount("a").cell !== firstCell)
    }

    @Test func givenAStoredDraft_whenTheMountedMembershipGrowsAndTheUserTypesAgain_thenTheDraftStillSurvivesThePrune() {
        // given
        let taskA = task("a", minute: 1)
        let rig = Rig([taskA])
        let mounted = rig.mount("a")
        rig.type("one", in: mounted)
        let cell = mounted.cell
        let taskB = task("b", parent: "a", minute: 2)
        rig.list([taskA, taskB])

        // when — a store that missed the continuation would hold only "a"; typing refreshes the aliases anyway.
        rig.type("one two", in: mounted)
        rig.list([taskB])

        // then
        #expect(rig.mount("b").cell === cell)
        #expect(rig.mount("b").text.wrappedValue == "one two")
    }
}
