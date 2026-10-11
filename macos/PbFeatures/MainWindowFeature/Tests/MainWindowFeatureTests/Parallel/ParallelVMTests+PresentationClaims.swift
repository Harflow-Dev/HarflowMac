import Foundation
@testable import MainWindowFeature
import MonitorCore
import Observation
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenEveryMemberSharesAnEnforcementFact_whenComputingTheHeaderClaims_thenItReflectsTheSharedFact() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let snapshotsSubject = harness.snapshotsSubject
        let tasksBox = harness.tasksBox
        let sharedEnforcement: [String: JSONValue] = [
            "os_enforced": .bool(true), "writes_confined": .bool(true),
            "network_access": .string("blocked")
        ]
        let task1 = task(id: "t1")
        let task2 = task(id: "t2")
        tasksBox.value["t1"] = task1
        tasksBox.value["t2"] = task2
        sut.didAppear()
        tasksSubject.send([task1, task2])
        await waitUntil { sut.columns.count == 2 && sut.isPresentationSettled }
        #expect(sut.headerClaimCaption == ParallelVM.fallbackFooter)

        // when — both snapshots share the same enforcement fact
        snapshotsSubject.send([
            "t1": task(id: "t1", enforcement: sharedEnforcement),
            "t2": task(id: "t2", enforcement: sharedEnforcement)
        ])

        // then
        await waitUntil { sut.headerPills == ["Writes: workspace + temp dirs", "No network", "OS sandbox"] }
        #expect(sut.headerPills == ["Writes: workspace + temp dirs", "No network", "OS sandbox"])
        #expect(sut.headerClaimCaption.isEmpty)
    }

    @Test func givenOnlyEnforcementChanges_whenHeaderClaimsRefresh_thenColumnPresentationAndActionsStayQuiet() async throws {
        // given
        let harness = makeSUT()
        let sampleTask = task(id: "t1", status: "completed")
        harness.tasksBox.value[sampleTask.taskID] = sampleTask
        harness.sut.didAppear()
        harness.tasksSubject.send([sampleTask])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        let before = harness.sut.columns[0]
        let beforeWrites = harness.sut.presentationWriteCount
        var changedRaw = sampleTask.raw
        changedRaw["enforcement"] = .object([
            "os_enforced": .bool(true), "network_access": .string("blocked")
        ])
        let changedTask = TaskInfo(.object(changedRaw))!

        // when — enforcement belongs in the header; the current lane's title, subtitle, rows and
        // action closures must not be replaced just because a claim pill changed.
        harness.snapshotsSubject.send([
            sampleTask.taskID: changedTask
        ])
        await waitUntil { harness.sut.headerPills == ["No network", "OS sandbox"] }

        // then
        let after = try #require(harness.sut.columns.first)
        #expect(after.title == before.title)
        #expect(after.subtitle == before.subtitle)
        #expect(after.rows == before.rows)
        #expect(after.activityRows == before.activityRows)
        #expect(after.task.status == before.task.status)
        #expect(harness.sut.presentationWriteCount == beforeWrites)
        harness.sut.didDisappear()
    }

    @Test func givenAnIdenticalHeaderClaimRefresh_whenObserved_thenNoDuplicateToolbarObservationPublishes() async {
        // given — establish the header's complete state and observe every toolbar-consumed value.
        let harness = makeSUT()
        let sampleTask = task(id: "t1", status: "completed", enforcement: [
            "os_enforced": .bool(true), "network_access": .string("blocked")
        ])
        harness.tasksBox.value[sampleTask.taskID] = sampleTask
        harness.sut.didAppear()
        harness.tasksSubject.send([sampleTask])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        harness.snapshotsSubject.send([sampleTask.taskID: sampleTask])
        await waitUntil { harness.sut.headerPills == ["No network", "OS sandbox"] }
        let before = (harness.sut.headerSubtitle, harness.sut.statusSummary, harness.sut.headerPills,
                      harness.sut.headerClaimCaption, harness.sut.showPrompt, harness.sut.canCancelAll)
        let writes = ObservationCounter()
        withObservationTracking {
            _ = harness.sut.headerSubtitle
            _ = harness.sut.statusSummary
            _ = harness.sut.headerPills
            _ = harness.sut.headerClaimCaption
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
        #expect((harness.sut.headerSubtitle, harness.sut.statusSummary, harness.sut.headerPills,
                 harness.sut.headerClaimCaption, harness.sut.showPrompt, harness.sut.canCancelAll) == before)
        harness.sut.didDisappear()
    }
}

@MainActor private final class ObservationCounter {
    var value = 0
}
