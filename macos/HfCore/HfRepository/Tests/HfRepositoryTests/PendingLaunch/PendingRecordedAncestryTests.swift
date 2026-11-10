import Combine
import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - PendingRecordedAncestryTests

@Suite struct PendingRecordedAncestryTests {
    @Test(arguments: ["continuation_of_task_id", "parent_task_id"])
    func givenRetainedAncestorOutsideLoadedHistory_whenSuccessorAdmitted_thenConversationNamespaceIncludesTheAncestor(key: String) async throws {
        // given
        let harness = PendingLaunchHarness()
        await harness.runner.setStatus(["task_id": .string("target"), "status": .string("running"), key: .string("source")], id: "target")
        await harness.runner.setStatus(["task_id": .string("source"), "status": .string("failed")], id: "source")
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        #expect(list.tasks.isEmpty)
        let runtime = QualificationRuntimeToken(client: harness.selected.value)
        let continuation = TaskContinuationRepositoryImpl(tooling: harness.tools, taskList: ContinuationTaskList(pages: ContinuationPages()),
                                                         actions: harness.actions, now: { .now })
        let sourceRequest = TaskContinuationRequest(runtime: runtime, conversationID: "source", sourceTaskID: "source")
        _ = await continuation.start(sourceRequest)
        let original = try #require(continuation.state(for: sourceRequest))
        guard case .uncertain? = original.outcome else { Issue.record("Expected retained unknown Continue evidence"); return }
        // when
        _ = try await list.admitRecorded("target", runtime: runtime, gate: PendingLaunchAdmissionGate())
        let namespace = Lineage.conversationID(of: "target", in: list.tasks)
        // then
        #expect(namespace == "source")
        #expect(Set(list.tasks.map(\.taskID)) == ["source", "target"])
        let successorRequest = TaskContinuationRequest(runtime: runtime, conversationID: namespace, sourceTaskID: "target")
        #expect(continuation.state(for: successorRequest)?.id == original.id)
        #expect(await harness.runner.calls.filter { $0.first == "status" }.map { $0.last! } == ["target", "source"])
    }

    @Test(arguments: ["selection", "runtime", "aba"])
    func givenDelayedAncestorRead_whenBindingChanges_thenNoPartialHistoryTitlesOrPublicationsEscape(change: String) async throws {
        // given
        let harness = PendingLaunchHarness()
        await harness.runner.setStatus(["task_id": .string("target"), "status": .string("running"),
                                        "continuation_of_task_id": .string("source"), "title": .string("Child")], id: "target")
        await harness.runner.setStatus(["task_id": .string("source"), "status": .string("failed"), "title": .string("Root")], id: "source")
        let latch = ContinuationLatch()
        await harness.runner.setStatusLatch(latch, id: "source")
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        let count = LockedBox(0)
        let subscription = list.tasksPublisher().sink { _ in count.mutate { $0 += 1 } }
        let initial = count.value
        let originalClient = harness.selected.value
        let gate = PendingLaunchAdmissionGate()
        let task = Task { try await list.admitRecorded("target", runtime: QualificationRuntimeToken(client: originalClient), gate: gate) }
        await latch.waitForArrival()
        // when
        if change == "selection" { gate.revoke() } else {
            harness.selected.mutate { $0 = CtlClient(executable: "/fixture/other/ctl", environment: [:], runner: harness.runner) }
            if change == "aba" { gate.revoke(); harness.selected.mutate { $0 = originalClient } }
        }
        await latch.release()
        let result = await task.result
        // then
        guard case .failure = result else { Issue.record("Obsolete ancestry admitted"); return }
        #expect(list.tasks.isEmpty && list.titles.isEmpty)
        #expect(count.value == initial)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenMissingRetainedAncestor_whenAdmitted_thenExplicitFailureHasNoInventedRootOrPartialInsertion() async throws {
        // given
        let harness = PendingLaunchHarness()
        await harness.runner.setStatus(["task_id": .string("target"), "status": .string("running"), "parent_task_id": .string("source")], id: "target")
        await harness.runner.setStatusOutput(pendingEnvelope([:], error: "task_not_found"), id: "source")
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        // when
        do {
            _ = try await list.admitRecorded("target", runtime: QualificationRuntimeToken(client: harness.selected.value), gate: PendingLaunchAdmissionGate())
            Issue.record("Missing ancestor was invented")
        } catch let error as PendingRecordedAdmissionFailure {
            guard case .ancestorRead(let id, _) = error else { Issue.record("Failure must name unavailable ancestor"); return }
            #expect(id == "source")
        }
        // then
        #expect(list.tasks.isEmpty && list.titles.isEmpty)
    }

    @Test func givenConversationCycle_whenAdmitted_thenNoPartialRowsArePublished() async throws {
        // given
        let harness = PendingLaunchHarness()
        await harness.runner.setStatus(["task_id": .string("target"), "status": .string("running"), "parent_task_id": .string("source")], id: "target")
        await harness.runner.setStatus(["task_id": .string("source"), "status": .string("failed"), "parent_task_id": .string("target")], id: "source")
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        // when
        do {
            _ = try await list.admitRecorded("target", runtime: QualificationRuntimeToken(client: harness.selected.value), gate: PendingLaunchAdmissionGate())
            Issue.record("Cyclic ancestry admitted")
        } catch let error as PendingRecordedAdmissionFailure { #expect(error == .cycle) }
        // then
        #expect(list.tasks.isEmpty && list.titles.isEmpty)
    }

    @Test func givenLongAncestry_whenThirtyTwoFreshReadsAreSpent_thenExplicitBoundRefusesWithoutPartialRows() async throws {
        // given
        let harness = PendingLaunchHarness()
        for index in 0 ..< 33 {
            await harness.runner.setStatus(["task_id": .string("node\(index)"), "status": .string("failed"),
                                            "continuation_of_task_id": .string("node\(index + 1)")], id: "node\(index)")
        }
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        // when
        do {
            _ = try await list.admitRecorded("node0", runtime: QualificationRuntimeToken(client: harness.selected.value), gate: PendingLaunchAdmissionGate())
            Issue.record("Unbounded ancestry admitted")
        } catch let error as PendingRecordedAdmissionFailure { #expect(error == .requestBudget) }
        // then
        #expect(list.tasks.isEmpty)
        #expect(await harness.runner.calls.filter { $0.first == "status" }.count == 32)
    }

    @Test func givenUnrelatedSpawner_whenTargetAdmitted_thenSpawnerIsNotTreatedAsConversationAncestry() async throws {
        // given
        let harness = PendingLaunchHarness()
        await harness.runner.setStatus(["task_id": .string("target"), "status": .string("running"), "spawned_by": .string("unrelated")], id: "target")
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        // when
        _ = try await list.admitRecorded("target", runtime: QualificationRuntimeToken(client: harness.selected.value), gate: PendingLaunchAdmissionGate())
        // then
        #expect(list.tasks.map(\.taskID) == ["target"])
        #expect(await harness.runner.calls.filter { $0.first == "status" }.count == 1)
    }
}
