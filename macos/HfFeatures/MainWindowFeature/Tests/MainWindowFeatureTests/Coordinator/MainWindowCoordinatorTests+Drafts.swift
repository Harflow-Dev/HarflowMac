import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - MainWindowCoordinatorTests + drafts

/// The coordinator's draft wiring: the membership it hands the store, the listing-driven reconciliation, and the
/// production builder keeping a standalone task's unsent message.
extension MainWindowCoordinatorTests {
    @MainActor private final class DraftRig {
        final class Listing {
            var tasks: [TaskInfo]
            init(_ tasks: [TaskInfo]) { self.tasks = tasks }
        }

        let coordinator: MainWindowCoordinator
        let listing: Listing
        let subject = PassthroughSubject<[TaskInfo], Never>()

        init(_ tasks: [TaskInfo]) {
            let listing = Listing(tasks)
            self.listing = listing
            let repository = MockTaskListRepository()
            given(repository).hasListed.willReturn(true)
            given(repository).listError.willReturn(nil)
            given(repository).tasks.willProduce { listing.tasks }
            given(repository).tasksPublisher().willReturn(subject.eraseToAnyPublisher())
            given(repository).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
            given(repository).listErrorPublisher().willReturn(Just<ToolError?>(nil).eraseToAnyPublisher())
            self.coordinator = MainWindowCoordinator(parent: MockCoordinator(), taskListRepository: repository)
        }

        /// Changes the listing and reconciles directly (the publisher hop is covered by its own test).
        func relist(_ tasks: [TaskInfo]) {
            listing.tasks = tasks
            coordinator.reconcileDrafts()
        }
    }

    private func draftTask(_ id: String, parent: String? = nil, spawnedBy: String? = nil, minute: Int,
                           extra: [String: JSONValue] = [:]) -> TaskInfo {
        var raw: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string("claude"), "status": .string("completed"),
            "started_at": .string(String(format: "2026-09-30T10:%02d:00Z", minute))
        ]
        if let parent { raw["parent_task_id"] = .string(parent) }
        if let spawnedBy { raw["spawned_by"] = .string(spawnedBy) }
        for (key, value) in extra { raw[key] = value }
        return TaskInfo(.object(raw))!
    }

    // MARK: - Membership

    @Test func givenAnUnknownId_whenKeyedForDrafts_thenItIsItsOwnConversationAndKeepsItsDraft() {
        // given
        let rig = DraftRig([])
        #expect(rig.coordinator.conversationKeyAndMembers(for: "nowhere").key == "nowhere")
        #expect(rig.coordinator.conversationKeyAndMembers(for: "nowhere").members == ["nowhere"])

        // when
        rig.coordinator.draftMount(for: "nowhere").text.wrappedValue = "kept"

        // then
        #expect(rig.coordinator.draftMount(for: "nowhere").text.wrappedValue == "kept")
    }

    @Test func givenLineageAndParentLinks_whenKeyed_thenTheKeyIsTheNormalisedFirstMemberAndMembersAreTheWholeConversation() {
        // given
        let tasks = [
            draftTask("a", minute: 1), draftTask("b", parent: "a", minute: 2),
            draftTask("c", minute: 3, extra: ["continuation_of_task_id": .string("b")]), draftTask("z", minute: 9)
        ]
        let rig = DraftRig(tasks)

        // when / then
        for id in ["a", "b", "c"] {
            let result = rig.coordinator.conversationKeyAndMembers(for: id)
            #expect(result.key == "a")
            #expect(result.key == rig.coordinator.normalisedConversationID(for: id))
            #expect(result.members == ["a", "b", "c"])
        }
        #expect(rig.coordinator.conversationKeyAndMembers(for: "z").members == ["z"])
    }

    @Test func givenWorkflowSessionMembers_whenKeyed_thenTheSessionBucketIsTheConversationAndMatchesTheListingPartition() {
        // given
        func orchestrator(_ id: String, minute: Int) -> TaskInfo {
            draftTask(id, minute: minute, extra: [
                "session_id": .string("shared"), "workflow_run_id": .string("run-1"), "workflow_role": .string("orchestrator")
            ])
        }
        let tasks = [orchestrator("w1", minute: 1), orchestrator("w2", minute: 2), draftTask("solo", minute: 3)]
        let rig = DraftRig(tasks)

        // when
        let partition = rig.coordinator.draftPartition()

        // then
        for id in ["w1", "w2"] {
            let result = rig.coordinator.conversationKeyAndMembers(for: id)
            #expect(result.key == "w1")
            #expect(result.members == ["w1", "w2"])
        }
        for task in tasks {
            let result = rig.coordinator.conversationKeyAndMembers(for: task.taskID)
            #expect(partition.keyOfMember[task.taskID] == result.key)
            #expect(partition.membersOfKey[result.key] == result.members)
        }
    }

    // MARK: - Retention through the seam

    @Test func givenADraft_whenTheTaskViewIsRebuiltAndAnotherConversationIsOpened_thenOnlyTheSameConversationKeepsIt() {
        // given
        let rig = DraftRig([draftTask("a", minute: 1), draftTask("b", parent: "a", minute: 2), draftTask("z", minute: 3)])
        let typed = rig.coordinator.draftMount(for: "a")
        typed.text.wrappedValue = "  keep me\n"

        // when / then
        #expect(rig.coordinator.draftMount(for: "a").cell === typed.cell)
        #expect(rig.coordinator.draftMount(for: "b").cell === typed.cell)
        #expect(rig.coordinator.draftMount(for: "z").cell !== typed.cell)
        #expect(rig.coordinator.draftMount(for: "z").text.wrappedValue.isEmpty)
    }

    @Test func givenUnrelatedSpawnedByTasks_whenOneHasADraft_thenTheOtherNeverInheritsIt() {
        // given
        let rig = DraftRig([draftTask("a", minute: 1), draftTask("x", spawnedBy: "a", minute: 2)])
        rig.coordinator.draftMount(for: "a").text.wrappedValue = "only for a"

        // when
        rig.relist([draftTask("x", spawnedBy: "a", minute: 2)])

        // then
        #expect(rig.coordinator.draftMount(for: "x").text.wrappedValue.isEmpty)
    }

    @Test func givenAContinuationThatAppearsWhileClosedThenAPrune_whenReconciled_thenTheDraftFollowsTheRekey() {
        // given
        let taskA = draftTask("a", minute: 1)
        let taskB = draftTask("b", parent: "a", minute: 2)
        let rig = DraftRig([taskA])
        let typed = rig.coordinator.draftMount(for: "a")
        typed.text.wrappedValue = "draft"

        // when
        rig.relist([taskA, taskB])
        rig.relist([taskB])

        // then
        #expect(rig.coordinator.draftMount(for: "b").cell === typed.cell)
    }

    @Test func givenABranchSplit_whenReconciled_thenTheOwnerBranchOtherwiseTheOldestSurvivorBranchGetsTheDraft() {
        // given
        let taskA = draftTask("a", minute: 1)
        let taskB = draftTask("b", parent: "a", minute: 2)
        let taskC = draftTask("c", parent: "a", minute: 3)
        let ownerCase = DraftRig([taskA, taskB, taskC])
        let ownerMount = ownerCase.coordinator.draftStore.makeMount(
            key: "a", members: ["a", "b", "c"], partition: ownerCase.coordinator.draftPartition()) { "c" }
        ownerMount.text.wrappedValue = "owned by c"
        let ownerCell = ownerMount.cell
        let prunedOwnerCase = DraftRig([taskA, taskB, taskC])
        let prunedOwnerMount = prunedOwnerCase.coordinator.draftMount(for: "a")
        prunedOwnerMount.text.wrappedValue = "owner gone"

        // when
        ownerCase.relist([taskB, taskC])
        prunedOwnerCase.relist([taskB, taskC])

        // then
        #expect(ownerCase.coordinator.draftMount(for: "c").cell === ownerCell)
        #expect(ownerCase.coordinator.draftMount(for: "b").text.wrappedValue.isEmpty)
        #expect(prunedOwnerCase.coordinator.draftMount(for: "b").cell === prunedOwnerMount.cell)
        #expect(prunedOwnerCase.coordinator.draftMount(for: "c").text.wrappedValue.isEmpty)
    }

    @Test func givenAMountedSplit_whenTheHomeIsAnotherBranch_thenEditingTheNonHomeBranchLeavesTheHomeDraftAlone() {
        // given
        let taskA = draftTask("a", minute: 1)
        let taskB = draftTask("b", parent: "a", minute: 2)
        let taskC = draftTask("c", parent: "a", minute: 3)
        let rig = DraftRig([taskA, taskB, taskC])
        let mounted = rig.coordinator.draftStore.makeMount(
            key: "a", members: ["a", "b", "c"], partition: rig.coordinator.draftPartition()) { "c" }
        mounted.text.wrappedValue = "draft for c"
        let home = mounted.cell

        // when
        rig.relist([taskB, taskC])
        mounted.text.wrappedValue = "typed in b"
        mounted.text.wrappedValue = ""

        // then
        #expect(mounted.cell !== home)
        #expect(home.text == "draft for c")
        #expect(rig.coordinator.draftMount(for: "c").cell === home)
        #expect(rig.coordinator.draftMount(for: "b").text.wrappedValue.isEmpty)
    }

    @Test func givenAJoin_whenReconciledAndTheWinnerIsSent_thenTheShadowedLoserIsNotShown() {
        // given
        let taskB = draftTask("b", parent: "a", minute: 2)
        let taskC = draftTask("c", parent: "a", minute: 3)
        let rig = DraftRig([taskB, taskC])
        let mountB = rig.coordinator.draftMount(for: "b")
        mountB.text.wrappedValue = "in b"
        let loser = mountB.cell
        let mountC = rig.coordinator.draftMount(for: "c")
        mountC.text.wrappedValue = "in c"

        // when
        rig.relist([draftTask("a", minute: 1), taskB, taskC])
        let shown = rig.coordinator.draftMount(for: "a")
        #expect(shown.text.wrappedValue == "in c")
        shown.text.wrappedValue = ""

        // then
        #expect(rig.coordinator.draftMount(for: "a").text.wrappedValue.isEmpty)
        #expect(rig.coordinator.draftStore.isShadowed(loser))
        #expect(loser.text == "in b")
    }

    @Test func givenAListingPublication_whenItArrives_thenStoredDraftsAreReconciledAgainstIt() async {
        // given
        let taskA = draftTask("a", minute: 1)
        let taskB = draftTask("b", parent: "a", minute: 2)
        let rig = DraftRig([taskA])
        let typed = rig.coordinator.draftMount(for: "a")
        typed.text.wrappedValue = "draft"

        // when — the continuation is published, then the earliest member is pruned.
        rig.listing.tasks = [taskA, taskB]
        rig.subject.send([taskA, taskB])
        await waitUntil { typed.testingMembers.contains("b") }
        rig.listing.tasks = [taskB]
        rig.subject.send([taskB])
        await waitUntil { typed.testingKey == "b" }

        // then
        #expect(rig.coordinator.draftMount(for: "b").cell === typed.cell)
    }

    // MARK: - Production builder

    @Test func givenTheProductionBuilder_whenTheSameTaskViewIsBuiltAgain_thenTheComposerDraftSurvivesAndOtherConversationsStayEmpty() throws {
        // given
        let rig = DraftRig([draftTask("a1", minute: 1), draftTask("a2", parent: "a1", minute: 2), draftTask("z", minute: 3)])
        let first = try #require(Self.findMount(in: rig.coordinator.buildTaskDetailView(id: "a1")))
        first.text.wrappedValue = "  line one\n\tline two \n"

        // when
        let again = try #require(Self.findMount(in: rig.coordinator.buildTaskDetailView(id: "a2")))
        let other = try #require(Self.findMount(in: rig.coordinator.buildTaskDetailView(id: "z")))

        // then
        #expect(again.cell === first.cell)
        #expect(Array(again.text.wrappedValue.utf8) == Array("  line one\n\tline two \n".utf8))
        #expect(other.text.wrappedValue.isEmpty)
    }

    private static func findMount(in value: Any, depth: Int = 0) -> TaskDraftMount? {
        // The view model reaches the coordinator, which reaches every mount: stop there.
        guard depth < 16, !(value is TaskDetailVM), !(value is MainWindowCoordinator) else { return nil }
        if let mount = value as? TaskDraftMount { return mount }
        for child in Mirror(reflecting: value).children {
            if let found = findMount(in: child.value, depth: depth + 1) { return found }
        }
        return nil
    }
}
