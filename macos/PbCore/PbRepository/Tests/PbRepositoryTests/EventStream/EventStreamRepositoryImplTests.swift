import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct EventStreamRepositoryImplTests {

    private func writeEventsFile(lines: [String]) -> (dir: URL, taskID: String, tasksDirectory: String) {
        let taskID = "evt-" + UUID().uuidString.prefix(8)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("\(taskID).events.jsonl")
        try? (lines.joined(separator: "\n") + "\n").write(to: path, atomically: true, encoding: .utf8)
        return (dir, String(taskID), dir.path)
    }

    private func taskStartedLine(prompt: String = "hello") -> String {
        #"{"v":1,"seq":1,"kind":"task_started","prompt":"\#(prompt)","backend":"claude"}"#
    }

    @Test func givenNoEventsPathExists_whenAcquiringAStream_thenItFallsBackToDevNull() async {
        // given — F4-13: `TaskTitle.eventsPath` returns nil for a task id that fails
        // `MonitorURL.isValidTaskID` (here, one containing "/"), so the tailer must fall back to
        // "/dev/null" rather than crash on a malformed path. The fallback path itself
        // (`TaskStream.path`) is private and not observable through the `EventStreamRepository` seam
        // without a production change, so this only proves the lease was really registered (ruling
        // out a no-op `acquire`) and that no events ever arrive.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository)

        // when
        let lease = sut.acquire("not/a-valid-id")

        // then — the lease was really registered...
        #expect(sut.leasedTaskIDs.contains("not/a-valid-id"))
        // ...and no crash, no events.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(sut.events(for: "not/a-valid-id").isEmpty)
        lease.release()
    }

    @Test func givenTheFirstLeaseOnATask_whenAcquired_thenItsSnapshotRefreshesAtOnce() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.value(taskID)).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository)

        // when
        let lease = sut.acquire(taskID)

        // then
        await verify(snapshotRepository).refresh(.value(taskID)).calledEventually(1, before: .seconds(3))
        lease.release()
    }

    @Test func givenASecondLease_whenAcquired_thenTheSnapshotIsNotRefreshedAgain() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository)

        // when
        let first = sut.acquire(taskID)
        await verify(snapshotRepository).refresh(.value(taskID)).calledEventually(1, before: .seconds(3))
        let second = sut.acquire(taskID)
        try? await Task.sleep(for: .milliseconds(50))

        // then — only the first lease triggered a refresh.
        verify(snapshotRepository).refresh(.value(taskID)).called(1)
        first.release()
        second.release()
    }

    @Test func givenEventsWritten_whenTailed_thenItemsAndEventsPublish() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine(prompt: "build the thing")])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository)

        // when
        let lease = sut.acquire(taskID)
        await waitUntil(timeout: 5) { !sut.events(for: taskID).isEmpty }

        // then
        #expect(sut.prompt(for: taskID) == "build the thing")
        #expect(!sut.items(for: taskID).isEmpty)
        lease.release()
    }

    @Test func givenAnUnknownEventKind_whenTailed_thenItStaysInEventsButNeverInItems() async {
        // given — F4-27: unknown kinds are kept for Raw events but never shown on the timeline.
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [
            taskStartedLine(),
            #"{"v":1,"seq":2,"kind":"something_new_and_unrecognized"}"#
        ])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository)

        // when
        let lease = sut.acquire(taskID)
        await waitUntil(timeout: 5) { sut.events(for: taskID).count >= 2 }

        // then
        #expect(sut.events(for: taskID).contains { $0.isUnknown })
        #expect(sut.items(for: taskID).allSatisfy { item in
            if case .started = item.body { return true }
            return false
        })
        lease.release()
    }

    @Test func givenALeaseReleasedTwice_whenReleased_thenTheSecondReleaseIsANoOp() async {
        // given — two leases on the same task, so a non-idempotent double release of `first` would
        // decrement the shared refcount twice and incorrectly drop `second`'s lease too. A single
        // lease can't distinguish "released once" from "released twice" — releasing it once already
        // empties `leasedTaskIDs`, so the old single-lease version of this test passed even against
        // a `release()` that always dropped the whole stream.
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository)
        let first = sut.acquire(taskID)
        let second = sut.acquire(taskID)
        await waitUntil { sut.leasedTaskIDs.contains(taskID) }
        #expect(sut.leasedTaskIDs.contains(taskID))

        // when — `first` is released twice.
        first.release()
        first.release()

        // then — `second`'s lease survives the redundant release, and nothing crashes.
        #expect(sut.leasedTaskIDs.contains(taskID))
        second.release()
        #expect(!sut.leasedTaskIDs.contains(taskID))
    }

    @Test func givenTwoLeases_whenOnlyOneIsReleased_thenTheTaskStaysLeased() async {
        // given
        let (dir, taskID, tasksDir) = writeEventsFile(lines: [taskStartedLine()])
        defer { try? FileManager.default.removeItem(at: dir) }
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(tasksDir)
        let snapshotRepository = MockTaskSnapshotRepository()
        given(snapshotRepository).refresh(.any).willReturn()
        let sut = EventStreamRepositoryImpl(toolEnvironment: toolEnvironment, snapshotRepository: snapshotRepository)
        let first = sut.acquire(taskID)
        let second = sut.acquire(taskID)
        await waitUntil { sut.leasedTaskIDs.contains(taskID) }

        // when
        first.release()

        // then
        #expect(sut.leasedTaskIDs.contains(taskID))
        second.release()
        #expect(!sut.leasedTaskIDs.contains(taskID))
    }
}
