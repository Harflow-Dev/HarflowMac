import Foundation
@testable import MonitorCore
import Testing

/// Phase 1, item 2: characterization tests for pure MonitorCore logic that had no coverage before
/// this migration. These describe CURRENT behaviour only — anything that looks like a bug is
/// reported in the migration/report notes, not fixed here (Phase 1 touches no production code).
/// Kept in their own file, separate from the 95 migrated tests, so the migrated count stays exact.

@Suite
struct TaskStatusCharacterizationTests {
    @Test
    func givenEachRawStatusString_whenCheckedForRunning_thenOnlyRunningIsTrue() {
        // given / when / then
        #expect(TaskStatus("running").isRunning)
        #expect(!TaskStatus("completed").isRunning)
        #expect(!TaskStatus("failed").isRunning)
        #expect(!TaskStatus("timed_out").isRunning)
        #expect(!TaskStatus("cancelled").isRunning)
        #expect(!TaskStatus("anything_else").isRunning)
    }

    @Test
    func givenEachStatusCase_whenReadingItsLabel_thenTheDisplayTextMatches() {
        // given / when / then
        #expect(TaskStatus.running.label == "Running")
        #expect(TaskStatus.completed.label == "Done")
        #expect(TaskStatus.failed.label == "Failed")
        #expect(TaskStatus.timedOut.label == "Timed out")
        #expect(TaskStatus.cancelled.label == "Cancelled")
        #expect(TaskStatus.other("weird").label == "weird")
    }
}

@Suite
struct TakeoverRefusalCharacterizationTests {
    @Test
    func givenEveryKnownRefusalCode_whenReadingItsHeadline_thenEachHasItsOwnPlainSentence() {
        // given / when / then
        let known: [String: String] = [
            "agent_caller": "Refused: this request came from inside an agent task. Take over is for a person at the Monitor.",
            "caller_undecidable": "Refused: polybridge could not confirm this request is not coming from an agent task, so it refuses rather than guess.",
            "descendants_not_stopped": "Refused: a sub-task of this task could not be confirmed stopped, so the session was not handed over.",
            "not_stopped": "Refused: the headless run could not be confirmed stopped.",
            "session_busy": "Refused: another run or takeover is using this session.",
            "binary_not_found": "Refused: the agent's command line tool is not on your login PATH.",
            "no_session": "Refused: the task never reported a session id, so there is nothing to resume.",
            "no_interactive_command": "Refused: this backend cannot resume this session interactively.",
            "repo_unavailable": "Refused: the task's repository folder no longer exists.",
            "not_ready": "Refused: there is no takeover waiting for a terminal.",
            "window_expired": "Refused: the terminal attached too late; the takeover window lapsed.",
            "already_attached": "Refused: a terminal is already attached to this takeover.",
            "pid_not_found": "Refused: the terminal's process could not be identified.",
            "unknown_task": "This task is not on disk any more.",
            "not_live_input": "This task was not started with live input, so it cannot take messages.",
            "owner_not_alive": "The server that owns this task is not confirmed alive, so the message could not be queued."
        ]
        for (code, headline) in known {
            #expect(TakeoverRefusal.headline(code: code) == headline, "\(code)")
        }
        // Three codes alias to the same headline.
        for code in ["closed", "settled", "exited"] {
            #expect(TakeoverRefusal.headline(code: code) == "This task no longer takes messages; use Continue once it has finished.", "\(code)")
        }
        // Only "Refused: ..." headlines are meant to show red in the header (TaskDetailView's
        // `message.hasPrefix("Refused")` rule) — "unknown_task" and the closed/settled/exited/
        // not_live_input/owner_not_alive headlines do NOT start with "Refused", so they would show
        // in the normal (non-red) color despite being refusals. Characterized as-is, not changed.
        #expect(!TakeoverRefusal.headline(code: "unknown_task")!.hasPrefix("Refused"))
        #expect(!TakeoverRefusal.headline(code: "not_live_input")!.hasPrefix("Refused"))
    }

    @Test
    func givenAnUnknownCode_whenReadingItsHeadline_thenThereIsNone() {
        // given / when / then
        #expect(TakeoverRefusal.headline(code: "brand_new_code") == nil)
    }

    @Test
    func givenAKnownCodeWithAndWithoutACtlMessage_whenExplained_thenTheHeadlineAndMessageCombine() {
        // given / when / then
        // A known code with a message: headline, then the ctl detail on its own line.
        #expect(
            TakeoverRefusal.explanation(code: "not_stopped", message: "task t survived")
                == "Refused: the headless run could not be confirmed stopped.\ntask t survived"
        )
        // A known code with no message: just the headline.
        #expect(TakeoverRefusal.explanation(code: "not_stopped", message: "") == "Refused: the headless run could not be confirmed stopped.")
        // An unknown code with a message: the message, with the code parenthesized.
        #expect(TakeoverRefusal.explanation(code: "brand_new", message: "why") == "why (brand_new)")
        // An unknown code with no message: a generic refusal naming the code.
        #expect(TakeoverRefusal.explanation(code: "brand_new", message: "") == "Refused (brand_new).")
    }
}

@Suite
struct LaunchEnvironmentAsListCharacterizationTests {
    @Test
    func givenAnEnvironmentDictionary_whenRenderedAsAList_thenEntriesAreKeyValueSortedByKey() {
        // given
        let env = ["PATH": "/usr/bin", "HOME": "/h", "A": "1"]
        // when
        let list = LaunchEnvironment.asList(env)
        // then
        #expect(list == ["A=1", "HOME=/h", "PATH=/usr/bin"])
    }

    @Test
    func givenAnEmptyEnvironment_whenRenderedAsAList_thenTheListIsEmpty() {
        // given / when / then
        #expect(LaunchEnvironment.asList([:]).isEmpty)
    }
}

@Suite
struct TaskInfoCharacterizationTests {
    func info(status: String, durationSeconds: Double? = nil, startedAt: String? = nil, group: String? = nil) -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string("t"), "status": .string(status)]
        if let durationSeconds { object["duration_seconds"] = .number(durationSeconds) }
        if let startedAt { object["started_at"] = .string(startedAt) }
        if let group { object["group"] = .string(group) }
        return TaskInfo(.object(object))!
    }

    @Test
    func givenATerminalTaskWithARecordedDuration_whenAskedForElapsed_thenTheRecordedDurationIsUsed() {
        // given
        let task = info(status: "completed", durationSeconds: 42, startedAt: "2020-01-01T00:00:00+00:00")
        // when / then
        // Terminal status: the recorded duration wins even though `now` is much later than start.
        #expect(task.elapsed(now: Date(timeIntervalSince1970: 5_000_000_000)) == 42)
    }

    @Test
    func givenARunningTaskWithAStartTime_whenAskedForElapsed_thenItIsMeasuredFromNow() {
        // given
        let started = Date(timeIntervalSince1970: 1_000_000_000)
        let task = info(status: "running", startedAt: ISO8601DateFormatter().string(from: started))
        // when
        let elapsed = task.elapsed(now: started.addingTimeInterval(90))
        // then
        #expect(elapsed == 90)
    }

    @Test
    func givenARunningTaskWithNoStartTimeButARecordedDuration_whenAskedForElapsed_thenTheDurationIsTheFallback() {
        // given
        let task = info(status: "running", durationSeconds: 7)
        // when / then
        #expect(task.elapsed() == 7)
    }

    @Test
    func givenNeitherAStartTimeNorADuration_whenAskedForElapsed_thenThereIsNone() {
        // given
        let task = info(status: "running")
        // when / then
        #expect(task.elapsed() == nil)
    }

    @Test
    func givenAnEmptyGroupString_whenReadingGroup_thenItIsTreatedAsNoGroup() {
        // given
        let task = info(status: "running", group: "")
        // when / then
        #expect(task.group == nil)
    }

    @Test
    func givenANonEmptyGroupString_whenReadingGroup_thenItIsKept() {
        // given
        let task = info(status: "running", group: "fanout")
        // when / then
        #expect(task.group == "fanout")
    }
}

@Suite
struct ISODateCharacterizationTests {
    @Test
    func givenTimestampsInEachSupportedShape_whenParsed_thenAllThreeShapesSucceed() {
        // given / when / then
        // Plain ISO8601, no fractional seconds.
        #expect(ISODate.parse("2026-09-25T01:02:03+00:00") != nil)
        // ISO8601 with (up to 3-digit) fractional seconds.
        #expect(ISODate.parse("2026-09-25T01:02:03.123+00:00") != nil)
        // Python's 6-digit microsecond isoformat, wider than ISO8601DateFormatter's 3-digit cap.
        #expect(ISODate.parse("2026-09-25T01:02:03.123456+00:00") != nil)
    }

    @Test
    func givenUnparsableText_whenParsed_thenTheResultIsNil() {
        // given / when / then
        #expect(ISODate.parse("not a date") == nil)
        #expect(ISODate.parse("") == nil)
    }
}

@Suite
struct JSONValueRenderedCharacterizationTests {
    @Test
    func givenAnObjectWithMixedTypes_whenRenderedCompactly_thenKeysAreSortedAndIntegersDropTheirDecimal() {
        // given
        let value = JSONValue.object(["z": .number(1), "a": .string("hi"), "m": .bool(true), "n": .null])
        // when
        let text = value.rendered()
        // then
        // sortedKeys: "a" before "m" before "n" before "z"; a whole-number Double renders as an Int.
        #expect(text == #"{"a":"hi","m":true,"n":null,"z":1}"#)
    }

    @Test
    func givenAFractionalNumber_whenRendered_thenItKeepsItsDecimal() {
        // given / when / then
        #expect(JSONValue.number(1.5).rendered() == "1.5")
    }

    @Test
    func givenAnArray_whenRenderedPretty_thenItIsMultiLine() {
        // given / when
        let text = JSONValue.array([.string("a"), .string("b")]).rendered(pretty: true)
        // then
        #expect(text.contains("\n"))
        #expect(text.contains("\"a\""))
    }
}

@Suite
struct TaskEventTimestampCharacterizationTests {
    @Test
    func givenBothTimestamps_whenAskedForTheDisplayTimestamp_thenObservedAtWins() throws {
        // given
        let event = try #require(TaskEvent(line: eventLine(0, "notice", #""text": "n", "source_ts": "2020-01-01T00:00:00+00:00""#)))
        // when / then
        // observed_at (set by eventLine) is preferred over source_ts when both are present.
        #expect(event.timestamp == event.observedAt)
        #expect(event.observedAt != nil)
    }

    @Test
    func givenOnlySourceTimestamp_whenAskedForTheDisplayTimestamp_thenItFallsBackToSourceTimestamp() {
        // given
        let line = #"{"v": 1, "seq": 0, "observed_at": null, "source_ts": "2020-01-01T00:00:00+00:00", "#
            + #""raw_offset": null, "task_id": "t1", "kind": "notice", "text": "n"}"#
        let event = TaskEvent(line: line)!
        // when / then
        #expect(event.observedAt == nil)
        #expect(event.timestamp == event.sourceTimestamp)
        #expect(event.timestamp != nil)
    }
}

@Suite
struct CtlDocumentFirstJSONObjectCharacterizationTests {
    @Test
    func givenLeadingBlankLinesBeforeTheJSONDocument_whenDecoded_thenTheDocumentIsStillFound() {
        // given
        let stdout = Data("\n\n{\"v\": 1, \"tasks\": []}\n".utf8)
        // when
        let result = CtlDocument.decode(stdout: stdout, stderr: "", exitCode: 0, command: "list")
        // then
        guard case .success(.tasks(let tasks)) = result else { Issue.record("expected .tasks, got \(result)"); return }
        #expect(tasks.isEmpty)
    }

    @Test
    func givenANonJSONLineFollowedByAJSONLine_whenDecoded_thenTheFirstValidJSONLineWins() {
        // given
        // A stray log line before the real JSON document, on its own line (firstJSONObject only
        // splits on newlines — it does not hunt for embedded JSON within a single line).
        let stdout = Data("some log noise\n{\"v\": 1, \"tasks\": []}\n".utf8)
        // when
        let result = CtlDocument.decode(stdout: stdout, stderr: "", exitCode: 0, command: "list")
        // then
        guard case .success(.tasks(let tasks)) = result else { Issue.record("expected .tasks, got \(result)"); return }
        #expect(tasks.isEmpty)
    }
}

@Suite
struct ToolErrorMessageCharacterizationTests {
    @Test
    func givenANotFoundError_whenReadingItsMessage_thenItNamesTheToolAndWhereItLooked() {
        // given
        let error = ToolError.notFound(tool: "polybridge-ctl", searched: ["/a", "/b"])
        // when / then
        #expect(error.message.contains("polybridge-ctl"))
        #expect(error.message.contains("/a, /b"))
        #expect(error.message.contains("uv tool install"))
    }

    @Test
    func givenATimedOutError_whenReadingItsMessage_thenItNamesTheToolAndTheSeconds() {
        // given
        let error = ToolError.timedOut(tool: "polybridge-ctl", seconds: 8)
        // when / then
        #expect(error.message == "`polybridge-ctl` did not answer within 8 s.")
    }

    @Test
    func givenALaunchFailedError_whenReadingItsMessage_thenItNamesTheToolAndTheDetail() {
        // given
        let error = ToolError.launchFailed(tool: "polybridge-ctl", detail: "no such file")
        // when / then
        #expect(error.message == "Could not run `polybridge-ctl`: no such file")
    }

    @Test
    func givenANonRefusedError_whenAskedForItsRefusalCode_thenThereIsNone() {
        // given / when / then
        #expect(ToolError.timedOut(tool: "x", seconds: 1).refusalCode == nil)
        #expect(ToolError.refused(code: "c", message: "m").refusalCode == "c")
    }
}
