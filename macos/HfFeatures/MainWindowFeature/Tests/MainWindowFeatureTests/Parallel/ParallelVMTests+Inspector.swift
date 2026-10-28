import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

extension ParallelVMTests {
    @Test func givenInspectorWithResumeChains_whenSelectionChangesAtSameWidth_thenOnlySelectedTurnsAreLeased() async throws {
        // given
        let harness = makeSUT()
        let sut = harness.sut.makeWorkflowActivity()
        let tasks = [task(id: "first", status: "completed", startedAt: Date(timeIntervalSince1970: 100)),
                     task(id: "a2", startedAt: Date(timeIntervalSince1970: 101), parentTaskID: "first"),
                     task(id: "second", startedAt: Date(timeIntervalSince1970: 200))]
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        var acquired: [String] = []
        harness.acquireEffectBox.value = { acquired.append($0) }
        sut.didAppear()
        defer { sut.didDisappear() }
        harness.tasksSubject.send(tasks)
        await waitUntil { sut.columns.count == 2 && sut.isPresentationSettled }
        #expect(sut.leasedMemberCount == 0)
        #expect(acquired.isEmpty)

        // when
        sut.selectConversation("first")
        sut.updateViewport(offset: 0, width: 220)
        await waitUntil { sut.leasedMemberCount == 2 && sut.isPresentationSettled }
        #expect(Set(acquired) == ["first", "a2"])
        acquired.removeAll()
        sut.selectConversation("second")
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // then
        #expect(sut.selectedConversationID == "second")
        #expect(acquired == ["second"])
        #expect(harness.releasedBox.value.isSuperset(of: ["first", "a2"]))
        #expect(sut.residentColumnCount == 1)
        sut.updateViewport(offset: 0, width: 0)
        #expect(sut.leasedMemberCount == 0)
        #expect(sut.selectedConversationID == "second")
    }

    @Test func givenManualInspectorSelection_whenMembershipReordersOrArrives_thenSelectionSurvivesUntilRemoved() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut.makeWorkflowActivity()
        let first = task(id: "first", startedAt: Date(timeIntervalSince1970: 100))
        let second = task(id: "second", startedAt: Date(timeIntervalSince1970: 200))
        harness.tasksBox.value = ["first": first, "second": second]
        sut.didAppear()
        defer { sut.didDisappear() }
        harness.tasksSubject.send([first, second])
        await waitUntil { sut.columns.count == 2 && sut.isPresentationSettled }
        sut.selectConversation("first")
        sut.updateViewport(offset: 0, width: 320)

        // when
        let third = task(id: "third", startedAt: Date(timeIntervalSince1970: 300))
        harness.tasksBox.value["third"] = third
        harness.tasksSubject.send([third, second, first])
        await waitUntil { sut.columns.count == 3 && sut.isPresentationSettled }
        #expect(sut.selectedConversationID == "first")
        harness.tasksBox.value["first"] = nil
        harness.tasksSubject.send([third, second])
        await waitUntil { sut.columns.count == 2 && sut.isPresentationSettled }

        // then
        #expect(sut.selectedConversationID == sut.columns.first?.id)
        #expect(sut.selectedConversationID != "first")
        #expect(sut.leasedMemberCount == 1)
        harness.tasksBox.value = [:]
        harness.tasksSubject.send([])
        await waitUntil { sut.columns.isEmpty && sut.isPresentationSettled }
        #expect(sut.selectedConversationID == nil)
        #expect(sut.leasedMemberCount == 0)
    }

    @Test func givenVisitedInspectorConversation_whenHiddenAndReopened_thenSelectionSnapshotAndReadingStateSurvive() async throws {
        // given
        let harness = makeSUT()
        let sut = harness.sut.makeWorkflowActivity()
        let tasks = [task(id: "first"), task(id: "second")]
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.itemsBox.value["first"] = [PreviewFixtures.textItem("Retained activity")]
        harness.availabilityBox.value["first"] = .available
        sut.didAppear()
        defer { sut.didDisappear() }
        harness.tasksSubject.send(tasks)
        await waitUntil { sut.columns.count == 2 && sut.isPresentationSettled }
        sut.selectConversation("first")
        sut.updateViewport(offset: 0, width: 420)
        await waitUntil { sut.columns.first { $0.id == "first" }?.rows.isEmpty == false && sut.isPresentationSettled }
        let original = try #require(sut.columns.first { $0.id == "first" })
        let state = sut.columnState(for: "first")
        state.followLive.suspend()
        state.anchor = ParallelVerticalAnchor(id: original.activityRows[0].id, index: 0, relativeOffset: -25)
        let anchor = state.anchor

        // when
        sut.suspendWorkflowActivity()
        #expect(sut.leasedMemberCount == 0)
        harness.itemsBox.value["first"] = []
        harness.availabilityBox.value["first"] = .loading
        sut.didAppear()
        harness.tasksSubject.send(tasks)
        sut.updateViewport(offset: 0, width: 500)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // then
        #expect(sut.selectedConversationID == "first")
        #expect(sut.columns.first { $0.id == "first" }?.rows == original.rows)
        #expect(sut.columnState(for: "first") === state)
        #expect(state.anchor == anchor)
        #expect(!state.followLive.isFollowing)
    }
}
