import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct TaskSnapshotRepositoryImplTests {

    @Test func givenCtlCannotBeLocated_whenRefreshingASnapshot_thenNothingChanges() async {
        // given — F4-12's ctl-not-found no-op. Seed a real snapshot first via a successful refresh,
        // so the "nothing changes" assertion below actually proves the stale snapshot survived,
        // rather than trivially passing because nothing was ever there. `ctl()` reads from a mutable
        // box rather than being re-`given` between calls — see the note in
        // `givenAnOtherFailure_whenRefreshingASnapshot_thenTheStaleSnapshotIsKept` on why re-`given`ing
        // the same member does not reliably swap the next call's answer.
        let toolEnvironment = MockToolEnvironmentRepository()
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(
            .success(CtlClient(
                executable: "/bin/echo", environment: [:],
                runner: StubProcessRunner(output: stdout(#"{"v":2,"task":{"task_id":"task-1","status":"running","backend":"claude"}}"#))
            ))
        )
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        await sut.refresh("task-1")
        #expect(sut.snapshot("task-1") != nil)

        // when — a later refresh cannot even locate ctl.
        resultBox.mutate { $0 = .failure(.notFound(tool: "polybridge-ctl", searched: [])) }
        await sut.refresh("task-1")

        // then — the stale snapshot is untouched.
        #expect(sut.snapshot("task-1")?.taskID == "task-1")
    }

    @Test func givenAnUnknownTaskRefusal_whenRefreshingASnapshot_thenTheSnapshotIsCleared() async {
        // given — seed a real snapshot first via a successful status, then switch to an unknown_task
        // refusal. `ctl()` reads from a mutable box for the same reason documented above.
        let toolEnvironment = MockToolEnvironmentRepository()
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(
            .success(CtlClient(
                executable: "/bin/echo", environment: [:],
                runner: StubProcessRunner(output: stdout(#"{"v":2,"task":{"task_id":"task-1","status":"running","backend":"claude"}}"#))
            ))
        )
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        await sut.refresh("task-1")
        #expect(sut.snapshot("task-1") != nil)

        // when — an unknown_task refusal supersedes the seeded snapshot.
        resultBox.mutate { $0 = .success(CtlClient(
            executable: "/bin/echo", environment: [:],
            runner: StubProcessRunner(output: stdout(#"{"v":2,"error":{"code":"unknown_task","message":"gone"}}"#))
        )) }
        await sut.refresh("task-1")

        // then
        #expect(sut.snapshot("task-1") == nil)
    }

    @Test func givenAnOtherFailure_whenRefreshingASnapshot_thenTheStaleSnapshotIsKept() async {
        // given: seed a real snapshot first. `ctl()` reads from a mutable box rather than being
        // re-stubbed with `given` between calls — Mockable's FIFO return queue only rotates past a
        // stub once a *later* one has already been registered and consumed, so re-stubbing after
        // the fact does not reliably swap the next call's answer (see the box pattern used
        // throughout this file and `TaskListRepositoryImplTests`).
        let toolEnvironment = MockToolEnvironmentRepository()
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(
            .success(CtlClient(
                executable: "/bin/echo", environment: [:],
                runner: StubProcessRunner(output: stdout(#"{"v":2,"task":{"task_id":"task-1","status":"running","backend":"claude"}}"#))
            ))
        )
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        await sut.refresh("task-1")
        #expect(sut.snapshot("task-1") != nil)

        // when: a later refresh fails with something other than unknown_task.
        resultBox.mutate { $0 = .success(CtlClient(
            executable: "/bin/echo", environment: [:],
            runner: StubProcessRunner(output: stdout(#"{"v":2,"error":{"code":"session_busy","message":"busy"}}"#))
        )) }
        await sut.refresh("task-1")

        // then
        #expect(sut.snapshot("task-1")?.taskID == "task-1")
    }

    @Test func givenTasksListed_whenEvictingKeepingASubset_thenOnlyThoseSurvive() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        let resultBox = LockedBox<Result<CtlClient, ToolError>>(
            .success(CtlClient(
                executable: "/bin/echo", environment: [:],
                runner: StubProcessRunner(output: stdout(#"{"v":2,"task":{"task_id":"a","status":"running","backend":"claude"}}"#))
            ))
        )
        given(toolEnvironment).ctl().willProduce { resultBox.value }
        await sut.refresh("a")
        resultBox.mutate { $0 = .success(CtlClient(
            executable: "/bin/echo", environment: [:],
            runner: StubProcessRunner(output: stdout(#"{"v":2,"task":{"task_id":"b","status":"running","backend":"claude"}}"#))
        )) }
        await sut.refresh("b")

        // when
        sut.evict(keeping: ["a"])

        // then
        #expect(sut.snapshot("a") != nil)
        #expect(sut.snapshot("b") == nil)
    }

    @Test func givenManyConcurrentRefreshes_whenTheyAllSucceed_thenNoSnapshotIsLost() async {
        // given — refreshes run concurrently (a lease's first refresh races the listing's loop);
        // each read-modify-write of the published dictionary must not drop another's result.
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner { call in
            let id = call.arguments.last ?? ""
            return .success(stdout(#"{"v":2,"task":{"task_id":"\#(id)","status":"running","backend":"claude"}}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        let ids = (0 ..< 200).map { "task-\($0)" }

        // when
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await sut.refresh(id) } }
        }

        // then
        #expect(sut.snapshots.count == ids.count)
        #expect(Set(ids).subtracting(sut.snapshots.keys).isEmpty)
    }

    @Test func givenAnOlderRefreshAnsweringLast_whenTwoRefreshesOverlap_thenTheNewerSnapshotStands() async {
        // given — the first status call is held and answers `running`; the second, started after
        // it, answers `completed` at once.
        let toolEnvironment = MockToolEnvironmentRepository()
        let gate = AsyncGate()
        let calls = LockedBox(0)
        let runner = StubProcessRunner { _ in
            calls.mutate { $0 += 1 }
            if calls.value == 1 {
                gate.waitSync()
                return .success(stdout(#"{"v":2,"task":{"task_id":"task-1","status":"running","backend":"claude"}}"#))
            }
            return .success(stdout(#"{"v":2,"task":{"task_id":"task-1","status":"completed","backend":"claude"}}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)

        // when
        let older = Task { await sut.refresh("task-1") }
        await waitUntil(timeout: 5) { calls.value >= 1 }
        await sut.refresh("task-1")
        #expect(sut.snapshot("task-1")?.status.isTerminal == true)
        gate.open()
        await older.value

        // then — the late `running` answer belongs to a superseded refresh and is dropped
        #expect(sut.snapshot("task-1")?.status.isTerminal == true)
    }

    @Test func givenSnapshotSubscriber_whenEqualReadsRepeat_thenDurationAndEnforcementChangesStillArrive() async {
        // given
        let environment = MockToolEnvironmentRepository()
        let payload = LockedBox(#"{"v":2,"task":{"task_id":"task","status":"running","duration_seconds":1,"enforcement":{"sandbox":"read-only"}}}"#)
        let runner = StubProcessRunner { _ in .success(stdout(payload.value)) }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: environment)
        let received = LockedBox<[[String: TaskInfo]]>([])
        let token = sut.snapshotsPublisher().sink { value in received.mutate { $0.append(value) } }
        // when
        await sut.refresh("task")
        await sut.refresh("task")
        payload.mutate { $0 = #"{"v":2,"task":{"task_id":"task","status":"running","duration_seconds":2,"enforcement":{"sandbox":"read-only"}}}"# }
        await sut.refresh("task")
        payload.mutate { $0 = #"{"v":2,"task":{"task_id":"task","status":"running","duration_seconds":2,"enforcement":{"sandbox":"workspace-write"}}}"# }
        await sut.refresh("task")
        payload.mutate { $0 = #"{"v":2,"task":{"task_id":"task","status":"running","duration_seconds":1,"enforcement":{"sandbox":"read-only"}}}"# }
        await sut.refresh("task")
        sut.evict(keeping: ["task"])
        sut.evict(keeping: [])
        sut.evict(keeping: [])
        // then
        #expect(runner.calls.count == 5)
        #expect(received.value.count == 6)
        #expect(received.value.map { $0["task"]?.durationSeconds } == [nil, 1, 2, 2, 1, nil])
        #expect(received.value[3]["task"]?.enforcement?["sandbox"]?.stringValue == "workspace-write")
        #expect(received.value.first?.isEmpty == true && received.value.last?.isEmpty == true)
        withExtendedLifetime(token) {}
    }

}
