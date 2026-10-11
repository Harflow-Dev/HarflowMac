@testable import MainWindowFeature
@testable import MonitorCore
import Testing

// MARK: - TaskSettledDurationTests

/// The one shared settled-duration guard (§1.6/§5.1/§6.2): the header badge, the Summary headline
/// and the Duration tile all show elapsed time only for a terminal task with an observed exit AND
/// a recorded duration — never a now-minus-start terminal fallback.
@Suite struct TaskSettledDurationTests {

    private func task(_ fields: [String: JSONValue]) -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string("t1"), "backend": .string("claude")]
        for (key, value) in fields { object[key] = value }
        return TaskInfo(.object(object))!
    }

    @Test func givenATerminalTaskWithAnObservedExitAndARecordedDuration_whenQueried_thenTheRecordedDurationReturns() {
        // given
        let settled = task(["status": .string("completed"), "exit_code": .number(0), "duration_seconds": .number(1260)])
        // when
        let seconds = TaskSettledDuration.seconds(for: settled)
        // then
        #expect(seconds == 1260)
    }

    @Test func givenATerminalTaskWithoutAnObservedExit_whenQueried_thenNoDurationIsClaimed() {
        // given — a recorded duration alone is not enough: without an observed exit the value the
        // old fallback fabricated must not appear as a settled elapsed time.
        let noExit = task(["status": .string("completed"), "duration_seconds": .number(1260)])
        // when / then
        #expect(TaskSettledDuration.seconds(for: noExit) == nil)
    }

    @Test func givenATerminalTaskWithAnObservedExitButNoRecordedDuration_whenQueried_thenNoDurationIsClaimed() {
        // given — the case the old `task.elapsed()` fallback fabricated an ever-growing value for.
        let noDuration = task(["status": .string("completed"), "exit_code": .number(0)])
        // when / then
        #expect(TaskSettledDuration.seconds(for: noDuration) == nil)
    }

    @Test func givenARunningTaskWithAnExitAndARecordedDuration_whenQueried_thenNoDurationIsClaimed() {
        // given — running tasks keep their live clock; the settled guard never answers for them.
        let running = task(["status": .string("running"), "exit_code": .number(0), "duration_seconds": .number(1260)])
        // when / then
        #expect(TaskSettledDuration.seconds(for: running) == nil)
    }

    @Test func givenTheSameSettledTask_whenQueriedTwice_thenTheValueNeverGrows() {
        // given — the guard is a pure read of the recorded duration, so unlike the old
        // now-minus-start fallback the answer cannot change as time passes.
        let settled = task(["status": .string("completed"), "exit_code": .number(0), "duration_seconds": .number(84)])
        // when
        let first = TaskSettledDuration.seconds(for: settled)
        let second = TaskSettledDuration.seconds(for: settled)
        // then
        #expect(first == second)
        #expect(first == 84)
    }

    @Test func givenEveryTerminalStatus_whenQueried_thenOnlyTheRecordedValueMatters() {
        // given / when / then — the guard treats every terminal status the same; each still needs
        // both the observed exit and the recorded duration.
        for status in ["completed", "failed", "cancelled", "timed_out"] {
            let withBoth = task(["status": .string(status), "exit_code": .number(1), "duration_seconds": .number(42)])
            let withoutExit = task(["status": .string(status), "duration_seconds": .number(42)])
            #expect(TaskSettledDuration.seconds(for: withBoth) == 42)
            #expect(TaskSettledDuration.seconds(for: withoutExit) == nil)
        }
    }
}
