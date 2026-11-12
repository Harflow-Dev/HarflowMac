import Foundation
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

extension ParallelVMTests {
    private static let sharedEnforcement: [String: JSONValue] = [
        "os_enforced": .bool(true), "writes_confined": .bool(true), "network_access": .string("blocked")
    ]

    @Test func givenEveryMemberSharesAnEnforcementFact_whenComputingTheTopBarMeta_thenItIsTheSharedSentence() async throws {
        // given
        let harness = makeSUT(publishesTopBar: true)
        let sut = harness.sut
        let task1 = task(id: "t1")
        let task2 = task(id: "t2")
        harness.tasksBox.value["t1"] = task1
        harness.tasksBox.value["t2"] = task2
        sut.didAppear()
        defer { sut.didDisappear() }
        harness.tasksSubject.send([task1, task2])
        await waitUntil { sut.columns.count == 2 && sut.isPresentationSettled }
        await waitUntil { sut.lastPublishedTopBar?.meta == ParallelVM.fallbackFooter }
        #expect(sut.lastPublishedTopBar?.meta == ParallelVM.fallbackFooter, "differing enforcement gives the fallback sentence")

        // when — both snapshots share the same enforcement fact
        let shared1 = task(id: "t1", enforcement: Self.sharedEnforcement)
        let shared2 = task(id: "t2", enforcement: Self.sharedEnforcement)
        harness.snapshotsSubject.send(["t1": shared1, "t2": shared2])

        // then
        let expected = try #require(EnforcementText.common([shared1, shared2]))
        await waitUntil { sut.lastPublishedTopBar?.meta == expected }
        #expect(sut.lastPublishedTopBar?.meta == expected)
        #expect(expected.hasPrefix("Enforced for every agent here:"))
    }

    @Test func givenOnlyEnforcementChanges_whenTheTopBarMetaRefreshes_thenColumnPresentationAndActionsStayQuiet() async throws {
        // given
        let harness = makeSUT(publishesTopBar: true)
        // A recorded exit and duration, so the arriving snapshot does not change the lane's status ("exit not observed", the clock).
        var settledRaw = task(id: "t1", status: "completed").raw
        settledRaw["exit_code"] = .number(0)
        settledRaw["duration_seconds"] = .number(5)
        let sampleTask = TaskInfo(.object(settledRaw))!
        harness.tasksBox.value[sampleTask.taskID] = sampleTask
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([sampleTask])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        let before = harness.sut.columns[0]
        let beforeWrites = harness.sut.presentationWriteCount
        var changedRaw = sampleTask.raw
        changedRaw["enforcement"] = .object(["os_enforced": .bool(true), "network_access": .string("blocked")])
        let changedTask = TaskInfo(.object(changedRaw))!
        let metaBefore = harness.sut.lastPublishedTopBar?.meta

        // when — enforcement belongs in the top bar; the lane's title, rows and action closures must not be replaced.
        harness.snapshotsSubject.send([sampleTask.taskID: changedTask])
        await waitUntil { harness.sut.lastPublishedTopBar?.meta != metaBefore }

        // then
        let after = try #require(harness.sut.columns.first)
        #expect(after.title == before.title)
        #expect(after.rows == before.rows)
        #expect(after.activityRows == before.activityRows)
        #expect(after.task.status == before.task.status)
        #expect(harness.sut.presentationWriteCount == beforeWrites)
    }

    @Test func givenAnIdenticalSnapshotRefresh_whenObserved_thenNothingIsPublishedToTheTopBarOrObservedState() async {
        // given — establish the complete state.
        let harness = makeSUT(publishesTopBar: true)
        let sampleTask = task(id: "t1", status: "completed", enforcement: ["os_enforced": .bool(true), "network_access": .string("blocked")])
        harness.tasksBox.value[sampleTask.taskID] = sampleTask
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([sampleTask])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        harness.snapshotsSubject.send([sampleTask.taskID: sampleTask])
        await waitUntil { harness.sut.lastPublishedTopBar?.isLoading == false && harness.sut.lastPublishedTopBar?.badge != nil }
        verify(harness.routing).publishTopBar(.matching { !$0.isLoading }, tag: .any).called(1)
        let before = (harness.sut.statusSummary, harness.sut.showPrompt, harness.sut.canCancelAll)
        let writes = ObservationCounter()
        withObservationTracking {
            _ = harness.sut.statusSummary
            _ = harness.sut.showPrompt
            _ = harness.sut.canCancelAll
        } onChange: {
            Task { @MainActor in writes.value += 1 }
        }

        // when — the same snapshot arrives again, as it does during an unchanged poll.
        harness.snapshotsSubject.send([sampleTask.taskID: sampleTask])
        for _ in 0 ..< 10 { await Task.yield() }

        // then
        #expect(writes.value == 0)
        #expect((harness.sut.statusSummary, harness.sut.showPrompt, harness.sut.canCancelAll) == before)
        verify(harness.routing).publishTopBar(.matching { !$0.isLoading }, tag: .any).called(1)
    }

    @Test func givenWorkflowInspectorAndPlainVMs_whenMembershipResolves_thenNeitherPublishesAGroupTopBar() async {
        // given
        let harness = makeSUT()
        let inspector = harness.sut.makeWorkflowActivity()
        let running = task(id: "t1", status: "running")
        harness.tasksBox.value[running.taskID] = running
        harness.sut.didAppear()
        inspector.didAppear()
        defer { harness.sut.didDisappear(); inspector.didDisappear() }

        // when
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.columns.count == 1 && inspector.columns.count == 1 }

        // then
        verify(harness.routing).publishTopBar(.any, tag: .any).called(0)
        verify(harness.routing).activateTopBar(tag: .any).called(0)
    }

    @Test func givenAnEmptyGroup_whenMembershipResolves_thenThereIsNoBadgeAndNoMeta() async {
        // given
        let harness = makeSUT(publishesTopBar: true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }

        // when
        harness.tasksSubject.send([])
        await waitUntil { harness.sut.lastPublishedTopBar?.isLoading == false }

        // then
        #expect(harness.sut.lastPublishedTopBar == GroupTopBarContent(title: "g1", badge: nil, meta: nil))
        #expect(harness.sut.isEmpty)
    }
}

@MainActor private final class ObservationCounter {
    var value = 0
}

extension ParallelVMTests {
    @Test func givenMemberStatusChanges_whenSnapshotsRefresh_thenTheTopBarBadgeImmediatelyReflectsCurrentCounts() async {
        // given
        let harness = makeSUT(publishesTopBar: true)
        let running = task(id: "t1", status: "running")
        harness.tasksBox.value[running.taskID] = running
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.lastPublishedTopBar?.badge?.label == "1 running" }
        // when
        harness.snapshotsSubject.send([running.taskID: task(id: "t1", status: "completed")])
        // then
        await waitUntil { harness.sut.lastPublishedTopBar?.badge?.label == "1 done" }
        #expect(harness.sut.lastPublishedTopBar?.badge?.label == "1 done")
        #expect(harness.sut.statusSummary == "1 done")
    }

    @Test func givenAFreshGroupVM_whenItAppearsBeforeMembershipResolves_thenItPublishesLoadingBeforeActivating() async {
        // given
        let harness = makeSUT(publishesTopBar: true)

        // when
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }

        // then — the first write is the loading content, and the tag activates only after it.
        verify(harness.routing).publishTopBar(.matching { $0.isLoading && $0.title == "g1" }, tag: .any).called(1)
        verify(harness.routing).activateTopBar(tag: .any).called(1)
    }
}
