import Combine
import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - Parallel initial activity presentation

extension ParallelVMTests {
    @Test func givenPendingAcquisitionWithoutRevealedMembers_whenBuilt_thenItRemainsLoading() throws {
        // given
        var base = emptyActivityBase()
        base.history = EventHistoryState(isLoading: true)
        let input = ParallelColumnInput(base: base, members: [], events: [], snapshot: nil)
        // when
        let result = try ParallelPresentationBuilder.build(input)
        // then
        #expect(result.isLoading)
        #expect(result.emptyText == nil)
    }

    @Test func givenAvailableMemberWithHiddenHistoryLoading_whenBuilt_thenEmptyActivityHasAnExplanation() throws {
        // given
        var base = emptyActivityBase()
        base.history = EventHistoryState(hasMore: true, isLoading: true)
        let member = ParallelMemberInput(task: base.task, items: [], prompt: nil, availability: .available)
        // when
        let result = try ParallelPresentationBuilder.build(ParallelColumnInput(base: base, members: [member], events: [], snapshot: nil))
        // then — hidden history loading must not replace already available visible activity with a skeleton.
        #expect(!result.isLoading)
        #expect(result.emptyText == "No activity to display.")
    }

    @Test func givenUnavailableActivity_whenBuilt_thenItsExplanationParticipatesInRenderingEquality() throws {
        // given
        let base = emptyActivityBase()
        let member = ParallelMemberInput(task: base.task, items: [], prompt: nil, availability: .unavailable)
        // when
        let result = try ParallelPresentationBuilder.build(ParallelColumnInput(base: base, members: [member], events: [], snapshot: nil))
        var available = result
        available.emptyText = "No activity to display."
        // then
        #expect(!result.isLoading)
        #expect(result.history.error == nil)
        #expect(result.emptyText == "Activity log unavailable.")
        #expect(result != available)
    }

    @Test func givenThreeStaggeredStreams_whenThirdDataOvertakesAnOlderBuild_thenLatestColumnsCommit() async throws {
        // given
        let gate = InitialColumnBuildGate()
        let harness = makeSUT(buildColumns: { inputs in
            let result = await ParallelPresentationBuilder.buildColumns(inputs)
            await gate.holdIfArmed()
            return result
        })
        let tasks = (0 ..< 3).map { task(id: "staggered-\($0)", status: "completed", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.sut.updateViewport(offset: 0, width: 1263)
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        for task in tasks {
            harness.itemSubjectsBox.value[task.taskID] = PassthroughSubject()
            harness.historyBox.value[task.taskID] = EventHistoryState(isLoading: true)
        }
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 3 && harness.sut.isPresentationSettled }
        #expect(harness.sut.columns.allSatisfy { $0.isResident && $0.isLoading && $0.emptyText == nil })
        let ids = harness.sut.columns.map(\.task.taskID)
        for id in ids.prefix(2) {
            let items = [PreviewFixtures.textItem("Initial \(id)")]
            harness.itemsBox.value[id] = items
            harness.itemSubjectsBox.value[id]?.send(items)
        }
        await waitUntil { harness.sut.isPresentationSettled && harness.sut.columns.prefix(2).allSatisfy { !$0.rows.isEmpty } }
        #expect(harness.sut.columns[2].isLoading)
        #expect(harness.sut.columns[2].emptyText == nil)

        // when — a stale completed build is deliberately held while the third stream catches up.
        await gate.arm()
        harness.itemSubjectsBox.value[ids[0]]?.send([PreviewFixtures.textItem("Older update")])
        await gate.waitUntilStarted()
        let thirdItems = [PreviewFixtures.textItem("Third column arrived")]
        harness.itemsBox.value[ids[2]] = thirdItems
        harness.itemSubjectsBox.value[ids[2]]?.send(thirdItems)
        harness.historySubjectsBox.value[ids[2]]?.send(EventHistoryState())
        await gate.release()
        await waitUntil { harness.sut.isPresentationSettled && harness.sut.columns.allSatisfy { !$0.rows.isEmpty && !$0.isLoading } }
        // then
        #expect(harness.sut.columns.count == 3)
        #expect(harness.sut.columns.allSatisfy { !$0.rows.isEmpty && !$0.isLoading && $0.emptyText == nil })
        let third = try #require(harness.sut.columns.first { $0.task.taskID == ids[2] })
        #expect(third.rows.count == 1)
        #expect(third.activityRows.count == 1)
    }

    private func emptyActivityBase() -> ParallelColumnPresentation {
        let task = task(id: "empty", status: "completed")
        return ParallelColumnPresentation(id: task.taskID, task: task, title: "Task", subtitle: "", isBusy: false,
            outcomeMessage: nil, showPrompt: false, prompt: nil, summary: nil, start: nil, memberTaskIDs: [task.taskID])
    }

    @Test func givenSharedThirdColumn_whenEvictedAndReacquired_thenItsFreshStreamWinsOverLateOldItems() async throws {
        // given
        let pool = ParallelTestLeasePool()
        let harness = makeSUT(leasePool: pool)
        let second = ParallelVM(groupName: "g1", useCase: harness.useCase, routing: harness.routing)
        let tasks = (0 ..< 3).map { task(id: "shared-\($0)", status: "completed", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        for task in tasks { harness.itemSubjectsBox.value[task.taskID] = PassthroughSubject() }
        harness.sut.updateViewport(offset: 0, width: 1263)
        second.updateViewport(offset: 0, width: 1263)
        harness.sut.didAppear()
        second.didAppear()
        defer { harness.sut.didDisappear(); second.didDisappear() }
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 3 && harness.sut.isPresentationSettled && second.isPresentationSettled }
        let id = try #require(harness.sut.columns.last?.task.taskID)
        let oldSubject = try #require(harness.itemSubjectsBox.value[id])
        #expect(pool.count(for: id) == 2)

        // when
        harness.sut.updateViewport(offset: 0, width: 421)
        await waitUntil { harness.sut.isPresentationSettled && pool.count(for: id) == 1 }
        let freshSubject = PassthroughSubject<[TimelineItem], Never>()
        harness.itemSubjectsBox.value[id] = freshSubject
        harness.sut.updateViewport(offset: 0, width: 1263)
        await waitUntil { harness.sut.isPresentationSettled && pool.count(for: id) == 2 }
        #expect(harness.sut.columns.first { $0.task.taskID == id }?.isLoading == true)
        let freshItem = PreviewFixtures.textItem("Fresh stream")
        freshSubject.send([freshItem])
        await waitUntil { harness.sut.isPresentationSettled && harness.sut.columns.first { $0.task.taskID == id }?.rows.count == 1 }
        oldSubject.send([PreviewFixtures.textItem("Late old stream")])
        await waitUntil { second.isPresentationSettled && second.columns.first { $0.task.taskID == id }?.rows.count == 1 }

        // then — one window's eviction cannot drop the other lease or revive its old subscription.
        let column = try #require(harness.sut.columns.first { $0.task.taskID == id })
        let row = try #require(column.rows.first)
        guard case .item(let item) = row.kind else { Issue.record("Expected the fresh activity item"); return }
        #expect(item == freshItem)
        #expect(!column.isLoading && column.emptyText == nil)
        #expect(pool.count(for: id) == 2)
    }
}

private actor InitialColumnBuildGate {
    private var armed = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true }
    func holdIfArmed() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            blocked = continuation
            for observer in observers { observer.resume() }
            observers.removeAll()
        }
    }

    func waitUntilStarted() async {
        if blocked != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() { blocked?.resume(); blocked = nil }
}
