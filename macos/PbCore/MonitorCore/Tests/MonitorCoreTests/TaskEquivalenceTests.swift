import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskEquivalenceTests

/// `TaskInfo.isEquivalent(to:)` — the polling-dedup equality: `duration_seconds` is ignored
/// **only** for a running task with a start time; everything else is compared in full.
@Suite struct TaskEquivalenceTests {

    func running(_ id: String, duration: Double, startedAt: String = "2026-10-17T10:00:00+00:00") -> TaskInfo {
        TaskInfo(.object([
            "task_id": .string(id), "status": .string("running"), "backend": .string("claude"),
            "started_at": .string(startedAt), "duration_seconds": .number(duration)
        ]))!
    }

    @Test func givenARunningTaskWithAStart_whenOnlyTheDurationChanges_thenTheyAreEquivalent() {
        // given / when / then
        #expect(running("t1", duration: 12).isEquivalent(to: running("t1", duration: 13)))
        #expect(running("t1", duration: 12) != running("t1", duration: 13))
    }

    @Test(arguments: ["completed", "failed", "timed_out", "cancelled"])
    func givenATerminalTask_whenOnlyTheDurationChanges_thenTheyAreNotEquivalent(status: String) {
        // given
        let task = { (duration: Double) in
            TaskInfo(.object([
                "task_id": .string("t1"), "status": .string(status), "backend": .string("claude"),
                "started_at": .string("2026-10-17T10:00:00+00:00"), "duration_seconds": .number(duration)
            ]))!
        }
        // when / then — a settled duration is recorded state, not presentation drift.
        #expect(!task(12).isEquivalent(to: task(13)))
    }

    @Test func givenARunningTaskWithoutAStart_whenOnlyTheDurationChanges_thenTheyAreNotEquivalent() {
        // given — the duration is the only clock this task has (the sidebar's layout-test fixture).
        let task = { (duration: Double) in
            TaskInfo(.object([
                "task_id": .string("t1"), "status": .string("running"), "backend": .string("claude"),
                "duration_seconds": .number(duration)
            ]))!
        }
        // when / then
        #expect(!task(61).isEquivalent(to: task(62)))
    }

    @Test func givenEquivalentRunningTasks_whenAnotherFieldChanges_thenTheyAreNotEquivalent() {
        // given
        var raw: [String: JSONValue] = [
            "task_id": .string("t1"), "status": .string("running"), "backend": .string("claude"),
            "started_at": .string("2026-10-17T10:00:00+00:00"), "duration_seconds": .number(12)
        ]
        let before = TaskInfo(.object(raw))!
        raw["summary"] = .string("finished while polling")
        raw["duration_seconds"] = .number(13)
        let after = TaskInfo(.object(raw))!
        // when / then — a real field change is never masked by the duration exemption.
        #expect(!before.isEquivalent(to: after))
    }

    @Test func givenOptionalEquivalence_thenNilAgainstATaskIsNeverEquivalent() {
        // given
        let some: TaskInfo? = running("t1", duration: 12)
        let none: TaskInfo? = nil
        // when
        let bothNil = none.isEquivalent(to: none)
        let nilAgainstTask = none.isEquivalent(to: some)
        let taskAgainstNil = some.isEquivalent(to: none)
        // then
        #expect(bothNil)
        #expect(!nilAgainstTask)
        #expect(!taskAgainstNil)
    }

    @Test func givenDictionaryEquivalence_thenOnlyDurationDriftIsIgnored() {
        // given
        let before = ["a": running("a", duration: 12), "b": running("b", duration: 5)]
        let drifted = ["a": running("a", duration: 13), "b": running("b", duration: 6)]
        var changed = before
        changed["a"] = TaskInfo(.object([
            "task_id": .string("a"), "status": .string("failed"), "backend": .string("claude"),
            "started_at": .string("2026-10-17T10:00:00+00:00"), "duration_seconds": .number(13)
        ]))!
        // when / then
        #expect(before.isEquivalent(to: drifted))
        #expect(!before.isEquivalent(to: changed))
        #expect(!before.isEquivalent(to: ["a": running("a", duration: 12)]))
    }
}
