import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

@MainActor
final class ParallelTestLeasePool {
    private var active: [UUID: String] = [:]
    var count: Int { active.count }
    var isEmpty: Bool { active.isEmpty }
    func count(for id: String) -> Int { active.values.filter { $0 == id }.count }
    func acquire(_ id: String) -> UUID {
        let token = UUID()
        active[token] = id
        return token
    }

    func release(_ token: UUID) { active[token] = nil }
}

private actor ParallelBuildGate {
    private var started = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func holdFirst() async {
        guard !started else { return }
        started = true
        for observer in observers { observer.resume() }
        observers.removeAll()
        await withCheckedContinuation { blocked = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() { blocked?.resume(); blocked = nil }
}

extension ParallelVMTests {
    @Test func givenTwoWindowsSharingMembers_whenOneEvictsAndCloses_thenOtherWindowLeasesRemain() async {
        let pool = ParallelTestLeasePool()
        let harness = makeSUT(leasePool: pool)
        let second = ParallelVM(groupName: "g1", useCase: harness.useCase, routing: harness.routing)
        let tasks = (0 ..< 8).map { task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.sut.updateViewport(offset: 0, width: 842)
        second.updateViewport(offset: 0, width: 842)
        harness.sut.didAppear()
        second.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 8 && second.columns.count == 8 && second.isPresentationSettled }
        let retained = Set(second.columns.filter(\.isResident).map(\.id))
        #expect(pool.count == 4)
        #expect(retained.allSatisfy { pool.count(for: $0) == 2 })
        harness.sut.updateViewport(offset: 421 * 4, width: 842)
        await waitUntil { harness.sut.isPresentationSettled }
        #expect(retained.allSatisfy { pool.count(for: $0) == 1 })
        harness.sut.didDisappear()
        #expect(pool.count == 2)
        #expect(second.leasedMemberCount == 2)
        second.didDisappear()
        #expect(pool.isEmpty)
    }

    @Test func givenAnOlderBuildCompletesLate_whenNewInputArrives_thenItCannotPublish() async {
        let gate = ParallelBuildGate()
        let harness = makeSUT(buildColumns: { inputs in
            // Produce a complete result before waiting, deliberately ignoring cancellation at the gate.
            let result = await ParallelPresentationBuilder.buildColumns(inputs)
            await gate.holdFirst()
            return result
        })
        let member = task(id: "task", startedAt: Date(timeIntervalSince1970: 1))
        harness.tasksBox.value = [member.taskID: member]
        harness.titlesBox.value = [member.taskID: "Older"]
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await gate.waitUntilStarted()
        harness.titlesBox.value = [member.taskID: "Current"]
        harness.titlesSubject.send([member.taskID: "Current"])
        await waitUntil { harness.sut.columns.first?.title == "Current" }
        #expect(harness.sut.builtColumnCount == 0)
        let writes = harness.sut.presentationWriteCount
        await gate.release()
        await waitUntil { harness.sut.columns.first?.title == "Current" && harness.sut.isPresentationSettled }
        #expect(harness.sut.presentationWriteCount == writes + 1)
        #expect(harness.sut.builtColumnCount == 1)
        harness.sut.didDisappear()
    }

    @Test func givenAnOldLifecycleBuild_whenTeardownAndReopenOccur_thenOnlyCurrentResultsApply() async {
        let gate = ParallelBuildGate()
        let harness = makeSUT(buildColumns: { inputs in
            let result = await ParallelPresentationBuilder.buildColumns(inputs)
            await gate.holdFirst()
            return result
        })
        let member = task(id: "task", startedAt: Date(timeIntervalSince1970: 1))
        harness.tasksBox.value = [member.taskID: member]
        harness.titlesBox.value = [member.taskID: "Old lifecycle"]
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await gate.waitUntilStarted()
        harness.sut.didDisappear()
        #expect(harness.sut.columns.isEmpty && harness.sut.leasedMemberCount == 0)
        harness.titlesBox.value = [member.taskID: "Reopened"]
        harness.sut.updateViewport(offset: 0, width: 842)
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        let updates = harness.sut.sourceUpdateCount
        await waitUntil { harness.sut.sourceUpdateCount > updates }
        let writes = harness.sut.presentationWriteCount
        await gate.release()
        await waitUntil { harness.sut.columns.first?.title == "Reopened" && harness.sut.isPresentationSettled }
        #expect(harness.sut.presentationWriteCount == writes + 1)
        #expect(harness.sut.builtColumnCount == 1)
        harness.sut.didDisappear()
    }
}
