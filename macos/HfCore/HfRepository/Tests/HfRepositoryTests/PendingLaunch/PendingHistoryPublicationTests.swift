import Combine
import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - PendingHistoryPublicationTests

@Suite struct PendingHistoryPublicationTests {
    @Test func givenPausedAdmissionPublication_whenNormalRefreshPublishesNewerRows_thenOldCaptureCannotClobberThem() async throws {
        // given
        let harness = PendingLaunchHarness()
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        let latch = ContinuationLatch()
        list.recordedPublicationBarrier = { await latch.park() }
        let publications = LockedBox<[[String]]>([])
        let subscription = list.tasksPublisher().sink { rows in publications.mutate { $0.append(rows.map(\.taskID).sorted()) } }
        let admission = Task { try await list.admitRecorded("target", runtime: QualificationRuntimeToken(client: harness.selected.value),
                                                          gate: PendingLaunchAdmissionGate()) }
        await latch.waitForArrival()
        await harness.runner.setHistory([
            ["task_id": .string("target"), "status": .string("completed")],
            ["task_id": .string("newer"), "status": .string("running")]
        ])
        // when
        let refreshed = await list.refreshAndWait()
        #expect((try? refreshed.get()) != nil)
        #expect(Set(list.tasks.map(\.taskID)) == ["target", "newer"])
        #expect(list.task("target")?.status == .completed)
        let afterRefresh = publications.value
        await latch.release()
        _ = try await admission.value
        // then
        #expect(Set(list.tasks.map(\.taskID)) == ["target", "newer"])
        #expect(list.task("target")?.status == .completed)
        #expect(publications.value == afterRefresh)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenReentrantHistoryListener_whenNewRevisionIsSubmitted_thenLaterListenerNeverReceivesNewThenOld() {
        // given
        let publication = TaskHistoryPublication()
        let first = makeTaskInfo("first")
        let second = makeTaskInfo("second")
        let values = LockedBox<[[String]]>([])
        let one = publication.publisher().sink { rows in
            if rows.map(\.taskID) == ["first"] { publication.submit([second], revision: 2) }
        }
        let two = publication.publisher().sink { rows in values.mutate { $0.append(rows.map(\.taskID)) } }
        // when
        publication.submit([first], revision: 1)
        // then
        #expect(values.value == [[], ["first"], ["second"]])
        #expect(publication.value.map(\.taskID) == ["second"])
        withExtendedLifetime((one, two)) {}
    }

    @Test func givenRunSuccess_whenRealHistoryRefreshCompletes_thenNewTaskIsVisibleBeforeRunReturns() async throws {
        // given
        let harness = PendingLaunchHarness()
        let list = TaskListRepositoryImplTests().makeSUT(toolEnvironment: harness.tools)
        await harness.runner.setHistory([["task_id": .string("target"), "status": .string("running")]])
        let actions = TaskActionRepositoryImpl(toolEnvironment: harness.tools, taskListRepository: list, snapshotRepository: NullTaskSnapshotRepository())
        // when
        let id = try await actions.run(RunRequest(backend: "fixture", repo: "/fixture/repo", prompt: "fixture"))
        // then
        #expect(id == "target")
        #expect(list.task(id)?.taskID == id)
        #expect(list.tasks.contains { $0.taskID == id })
    }

    @Test func givenHistorySubscriberCrossThreadReentry_whenItWaitsForNewRawRows_thenDrainDoesNotHoldAStateLock() {
        // given
        let publication = TaskHistoryPublication()
        let first = makeTaskInfo("first")
        let second = makeTaskInfo("second")
        let completed = LockedBox(false)
        let one = publication.publisher().sink { rows in
            guard rows.map(\.taskID) == ["first"] else { return }
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                publication.submit([second], revision: 2)
                completed.mutate { $0 = publication.value.map(\.taskID) == ["second"] }
                done.signal()
            }
            #expect(done.wait(timeout: .now() + 2) == .success)
        }
        // when
        publication.submit([first], revision: 1)
        // then
        #expect(completed.value)
        #expect(publication.value.map(\.taskID) == ["second"])
        withExtendedLifetime(one) {}
    }

}
