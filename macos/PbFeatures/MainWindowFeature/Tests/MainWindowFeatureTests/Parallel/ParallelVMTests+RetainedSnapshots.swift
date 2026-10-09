import Combine
import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenVisitedPrunedConversation_whenOffscreenIdentityChanges_thenRetainedActivitySurvives() async throws {
        let harness = makeSUT()
        let first = task(id: "first", startedAt: Date(timeIntervalSince1970: 100))
        let last = task(id: "last", startedAt: Date(timeIntervalSince1970: 200), parentTaskID: "first")
        harness.tasksBox.value = ["first": first, "last": last]
        harness.itemsBox.value["last"] = [PreviewFixtures.textItem("Retained activity")]
        harness.availabilityBox.value["first"] = .available
        harness.availabilityBox.value["last"] = .available
        harness.sut.updateViewport(offset: 0, width: 842)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([first, last])
        await waitUntil { harness.sut.isPresentationSettled && harness.sut.columns.first?.rows.isEmpty == false }
        let rows = try #require(harness.sut.columns.first).rows
        harness.sut.updateViewport(offset: 0, width: 0)
        harness.tasksBox.value = ["last": last]
        harness.tasksSubject.send([last])
        await waitUntil { harness.sut.columns.first?.id == "last" && harness.sut.isPresentationSettled }
        #expect(harness.sut.columns.first?.rows == rows)
        #expect(harness.sut.leasedMemberCount == 0)
        harness.itemsBox.value["last"] = []
        harness.availabilityBox.value["last"] = .loading
        harness.sut.updateViewport(offset: 0, width: 842)
        await waitUntil { harness.sut.isPresentationSettled && harness.sut.leasedMemberCount == 1 }
        #expect(harness.sut.columns.first?.rows == rows)
    }

    @Test func givenVisitedActivity_whenOffscreenAndRevisited_thenSnapshotStaysUntilFreshActivityCommits() async throws {
        let harness = makeSUT()
        let tasks = (0 ..< 8).map { task(id: "retained-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        for task in tasks {
            harness.itemsBox.value[task.taskID] = [PreviewFixtures.textItem("Original \(task.taskID)")]
            harness.availabilityBox.value[task.taskID] = .available
            harness.itemSubjectsBox.value[task.taskID] = PassthroughSubject()
        }
        harness.sut.updateViewport(offset: 0, width: 842)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let first = try #require(harness.sut.columns.first)
        let oldSubject = try #require(harness.itemSubjectsBox.value[first.task.taskID])
        #expect(!first.rows.isEmpty)
        #expect(harness.sut.leasedMemberCount == 2)
        let state = harness.sut.columnState(for: first.id)
        state.followLive.suspend()
        state.anchor = ParallelVerticalAnchor(id: first.activityRows[0].id, index: 0, relativeOffset: -40)
        let anchor = state.anchor

        harness.sut.updateViewport(offset: 421 * 4, width: 842)
        await waitUntil { harness.sut.isPresentationSettled }
        let paused = try #require(harness.sut.columns.first { $0.id == first.id })
        #expect(!paused.isVisible && paused.isResident)
        #expect(paused.rows == first.rows && paused.activityRows == first.activityRows)
        #expect(harness.releasedBox.value.contains(first.task.taskID))
        let unvisitedAreEmpty = harness.sut.columns.filter { !$0.isResident }.allSatisfy(\.rows.isEmpty)
        #expect(unvisitedAreEmpty)
        let builds = harness.sut.builtColumnCount
        oldSubject.send([PreviewFixtures.textItem("Must be ignored while offscreen")])
        await Task.yield()
        await Task.yield()
        #expect(harness.sut.builtColumnCount == builds)
        #expect(harness.sut.columns.first { $0.id == first.id }?.rows == first.rows)

        let freshSubject = PassthroughSubject<[TimelineItem], Never>()
        harness.itemSubjectsBox.value[first.task.taskID] = freshSubject
        harness.itemsBox.value[first.task.taskID] = []
        harness.availabilityBox.value[first.task.taskID] = .loading
        harness.sut.updateViewport(offset: 0, width: 842)
        await waitUntil { harness.sut.isPresentationSettled && harness.sut.leasedMemberCount == 2 }
        #expect(harness.sut.columns.first { $0.id == first.id }?.rows == first.rows)
        #expect(harness.sut.columnState(for: first.id).anchor == anchor)
        #expect(!harness.sut.columnState(for: first.id).followLive.isFollowing)

        let fresh = PreviewFixtures.textItem("Fresh activity")
        freshSubject.send([fresh])
        await waitUntil { harness.sut.isPresentationSettled && harness.sut.columns.first { $0.id == first.id }?.rows != first.rows }
        let refreshed = try #require(harness.sut.columns.first { $0.id == first.id })
        guard case .item(let item) = refreshed.rows.first?.kind else { Issue.record("Expected refreshed activity"); return }
        #expect(item == fresh)
        harness.sut.didDisappear()
        #expect(harness.sut.columns.isEmpty && harness.sut.leasedMemberCount == 0)
    }
}
