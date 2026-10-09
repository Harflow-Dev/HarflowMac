import Combine
import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenUnknownViewport_whenMembershipArrives_thenNoActivityIsAcquired() async {
        let harness = makeSUT()
        harness.sut.updateViewport(offset: 0, width: 0)
        let tasks = (0 ..< 64).map { task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 64 && harness.sut.isPresentationSettled }
        #expect(harness.sut.leasedMemberCount == 0)
        #expect(harness.sut.residentColumnCount == 0)
        #expect(harness.sut.columns.allSatisfy { !$0.isResident && $0.rows.isEmpty })
        harness.sut.didDisappear()
    }

    @Test func givenManyConversations_whenViewportMoves_thenOnlyVisibleMembersAreLeased() async {
        let harness = makeSUT()
        harness.sut.updateViewport(offset: 0, width: 842)
        let tasks = (0 ..< 64).map { task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 64 && harness.sut.isPresentationSettled }
        #expect(harness.sut.residentColumnCount == 2)
        #expect(harness.sut.leasedMemberCount == 2)
        let original = Set(harness.sut.columns.filter(\.isResident).map(\.id))
        harness.sut.updateViewport(offset: 421 * 20, width: 842)
        await waitUntil { harness.sut.isPresentationSettled }
        #expect(harness.sut.residentColumnCount == 2)
        #expect(harness.sut.leasedMemberCount == 2)
        #expect(original.isSubset(of: harness.releasedBox.value))
        #expect(harness.sut.columns.filter { !$0.isResident }.allSatisfy { $0.rows.isEmpty && $0.activityRows.isEmpty })
        harness.sut.didDisappear()
    }

    @Test func givenUnchangedPolling_whenInputsRepeat_thenNoBuildOrPublicationOccurs() async {
        let harness = makeSUT()
        let tasks = [task(id: "task", startedAt: Date(timeIntervalSince1970: 100))]
        harness.tasksBox.value = ["task": tasks[0]]
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        let builds = harness.sut.builtColumnCount
        let writes = harness.sut.presentationWriteCount
        harness.tasksSubject.send(tasks)
        harness.busySubject.send([])
        harness.snapshotsSubject.send([:])
        await Task.yield()
        await Task.yield()
        #expect(harness.sut.builtColumnCount == builds)
        #expect(harness.sut.presentationWriteCount == writes)
        harness.sut.didDisappear()
    }

    @Test func givenRapidViewportChanges_whenWorkerSettles_thenOnlyLatestResidencyApplies() async {
        let harness = makeSUT()
        harness.sut.updateViewport(offset: 0, width: 842)
        let tasks = (0 ..< 256).map { task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 256 }
        for index in 0 ..< 30 { harness.sut.updateViewport(offset: CGFloat(index) * 421, width: 842) }
        harness.sut.updateViewport(offset: 0, width: 842)
        await waitUntil { harness.sut.isPresentationSettled }
        #expect(harness.sut.residentColumnCount == 2)
        #expect(harness.sut.leasedMemberCount == 2)
        let firstTwoAreResident = harness.sut.columns.prefix(2).allSatisfy(\.isResident)
        #expect(firstTwoAreResident)
        let unvisitedAreEmpty = harness.sut.columns.filter { !$0.isResident }.allSatisfy(\.rows.isEmpty)
        #expect(unvisitedAreEmpty)
        harness.sut.didDisappear()
        #expect(harness.sut.leasedMemberCount == 0)
        #expect(harness.sut.columns.isEmpty)
    }

    @Test func givenOneMemberActivity_whenItChanges_thenOnlyItsResidentColumnBuilds() async throws {
        let harness = makeSUT()
        harness.sut.updateViewport(offset: 0, width: 842)
        let tasks = (0 ..< 8).map { task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        let subject = PassthroughSubject<[TimelineItem], Never>()
        harness.itemSubjectsBox.value["task-7"] = subject
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let builds = harness.sut.builtColumnCount
        let event = try #require(TaskEvent(line: "{\"v\":1,\"seq\":1,\"kind\":\"assistant_text\",\"text\":\"hello\"}"))
        subject.send(Timeline.items(from: [event]))
        await waitUntil { harness.sut.columns.first?.rows.count == 1 && harness.sut.isPresentationSettled }
        #expect(harness.sut.builtColumnCount == builds + 1)
        harness.sut.didDisappear()
    }

    @Test func givenLongResumeChains_whenOnlyTwoColumnsAreVisible_thenAllTheirTurnsAreLeased() async throws {
        let harness = makeSUT()
        harness.sut.updateViewport(offset: 0, width: 842)
        var tasks: [TaskInfo] = []
        for column in 0 ..< 8 {
            for turn in 0 ..< 16 {
                tasks.append(task(id: "c\(column)-t\(turn)", status: turn == 15 ? "running" : "completed",
                    startedAt: Date(timeIntervalSince1970: Double(column * 100 + turn)),
                    parentTaskID: turn == 0 ? nil : "c\(column)-t\(turn - 1)"))
            }
        }
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        let event = try #require(TaskEvent(line: "{\"v\":1,\"seq\":1,\"kind\":\"assistant_text\",\"text\":\"synthetic turn\"}"))
        for task in tasks {
            harness.itemsBox.value[task.taskID] = Timeline.items(from: [event])
            harness.availabilityBox.value[task.taskID] = .available
        }
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        #expect(harness.sut.residentColumnCount == 2)
        #expect(harness.sut.leasedMemberCount == 32)
        for column in harness.sut.columns where column.isResident {
            #expect(column.rows.count == 1)
            #expect(column.rows.first?.taskID == column.task.taskID, "seeded historical turns stay hidden behind the chronological frontier")
            #expect(column.history.hasMore, "the fifteen previous seeded turns remain available")
            #expect(harness.sut.columnState(for: column.id).activityMembers == [column.task.taskID])
        }
        harness.sut.didDisappear()
    }

    @Test func givenResidencyGeometry_whenOffsetIsClamped_thenIntervalsAreBounded() {
        #expect(ParallelResidency.indices(count: 64, offset: 0, width: 842, stride: 421) == 0 ..< 3)
        #expect(ParallelResidency.indices(count: 64, offset: 421, width: 842, stride: 421) == 0 ..< 4)
        #expect(ParallelResidency.indices(count: 64, offset: -50, width: 842, stride: 421) == 0 ..< 3)
        #expect(ParallelResidency.indices(count: 64, offset: .infinity, width: 842, stride: 421).isEmpty)
        #expect(ParallelResidency.indices(count: 64, offset: 0, width: 0, stride: 421).isEmpty)
        #expect(ParallelResidency.indices(count: 2, offset: 100_000, width: 842, stride: 421) == 0 ..< 2)
    }
}
