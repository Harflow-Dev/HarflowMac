import XCTest
@testable import MonitorCore

/// Lines shaped exactly as `events.EventLog.write` produces them.
func eventLine(_ seq: Int, _ kind: String, _ fields: String = "") -> String {
    let extra = fields.isEmpty ? "" : ", " + fields
    return #"{"v": 1, "seq": \#(seq), "observed_at": "2026-09-25T01:00:\#(String(format: "%02d", seq % 60)).000000+00:00", "source_ts": null, "raw_offset": null, "task_id": "t1", "kind": "\#(kind)"\#(extra)}"#
}

final class EventDecodingTests: XCTestCase {
    /// Every kind in `events.EVENT_KINDS` (src/polybridge/events.py). If that set grows, this
    /// list and `TaskEvent.Kind` grow with it — the frozen v1 contract.
    let v1Kinds = ["task_started", "assistant_text", "tool_call", "tool_result", "user_message", "usage", "notice", "task_finished", "undelivered"]

    func testEveryV1KindDecodesToItsOwnCase() {
        for (index, kind) in v1Kinds.enumerated() {
            let event = TaskEvent(line: eventLine(index, kind))
            XCTAssertNotNil(event, kind)
            XCTAssertFalse(event!.isUnknown, "\(kind) must not be .unknown")
        }
    }

    func testFields() throws {
        let started = try XCTUnwrap(TaskEvent(line: eventLine(0, "task_started", #""backend": "claude", "freedom": "read_only", "prompt": "Fix it\nplease", "reasoning_effort": "high", "spawned_by": "p", "live_input": true"#)))
        guard case .taskStarted(let s) = started.kind else { return XCTFail() }
        XCTAssertEqual(s.prompt, "Fix it\nplease")
        XCTAssertEqual(s.reasoningEffort, "high")
        XCTAssertEqual(s.spawnedBy, "p")
        XCTAssertEqual(s.liveInput, true)
        XCTAssertEqual(started.seq, 0)
        XCTAssertNotNil(started.observedAt)

        let call = try XCTUnwrap(TaskEvent(line: eventLine(1, "tool_call", #""call_id": "c1", "tool": "Edit", "category": "edit", "input_preview": "{}", "path": "/r/a.swift", "edit": {"old": "a", "new": "b"}"#)))
        guard case .toolCall(let c) = call.kind else { return XCTFail() }
        XCTAssertEqual(c.path, "/r/a.swift")
        XCTAssertEqual(c.editOld, "a")
        XCTAssertEqual(c.editNew, "b")
        XCTAssertEqual(c.headline, "/r/a.swift")

        let result = try XCTUnwrap(TaskEvent(line: eventLine(2, "tool_result", #""call_id": "c1", "ok": false, "output_tail": "boom", "exit_code": 2"#)))
        XCTAssertEqual(result.kind, .toolResult(.init(callID: "c1", ok: false, outputTail: "boom", exitCode: 2)))

        let message = try XCTUnwrap(TaskEvent(line: eventLine(3, "user_message", #""text": "more", "source": "injected", "message_id": "m1""#)))
        XCTAssertEqual(message.kind, .userMessage(text: "more", source: "injected", messageID: "m1"))

        let undelivered = try XCTUnwrap(TaskEvent(line: eventLine(4, "undelivered", #""message_id": "m2", "text": "late", "reason": "closed""#)))
        XCTAssertEqual(undelivered.kind, .undelivered(messageID: "m2", text: "late", reason: "closed"))

        let finished = try XCTUnwrap(TaskEvent(line: eventLine(5, "task_finished", #""status": "completed", "exit_code": 0, "summary": "ok", "observed": true"#)))
        XCTAssertEqual(finished.kind, .taskFinished(status: "completed", exitCode: 0, summary: "ok", observed: true))
    }

    func testUnknownKindIsKeptAsUnknownAndIgnoredByTheTimeline() throws {
        let event = try XCTUnwrap(TaskEvent(line: eventLine(0, "future_kind", #""x": 1"#)))
        XCTAssertEqual(event.kind, .unknown("future_kind"))
        XCTAssertTrue(Timeline.items(from: [event]).isEmpty)
    }

    func testNotAnEvent() {
        XCTAssertNil(TaskEvent(line: "not json"))
        XCTAssertNil(TaskEvent(line: #"{"v": 2, "seq": 0, "kind": "notice"}"#), "another schema version is not read")
        XCTAssertNil(TaskEvent(line: #"{"v": 1, "seq": 0}"#))
        XCTAssertNil(TaskEvent(line: "[1,2]"))
    }

    func testTimelineMergesResultsIntoCalls() throws {
        let events = [
            eventLine(0, "task_started", #""prompt": "Do the thing""#),
            eventLine(1, "assistant_text", #""text": "Looking""#),
            eventLine(2, "assistant_text", #""text": "   ""#),
            eventLine(3, "tool_call", #""call_id": "a", "tool": "Bash", "category": "shell", "input_preview": "{}", "command": "make test""#),
            eventLine(4, "tool_call", #""call_id": "b", "tool": "Read", "category": "read", "input_preview": "{}", "path": "x""#),
            eventLine(5, "tool_result", #""call_id": "a", "ok": true, "output_tail": "ok", "exit_code": 0"#),
            eventLine(6, "tool_result", #""call_id": "zzz", "ok": true, "output_tail": "orphan""#),
            eventLine(7, "usage", #""total_cost_usd": 0.1, "num_turns": 1"#),
            eventLine(8, "tool_call", #""call_id": "c", "tool": "Edit", "category": "edit", "input_preview": "{}""#),
        ].compactMap(TaskEvent.init(line:))
        let items = Timeline.items(from: events)
        XCTAssertEqual(items.map(\.id), [0, 1, 3, 4, 8])
        guard case .tool(let call, let result) = items[2].body else { return XCTFail() }
        XCTAssertEqual(call.command, "make test")
        XCTAssertEqual(result?.exitCode, 0)
        XCTAssertEqual(Timeline.current(in: items)?.id, 8, "the latest call without a result is what is happening now")
        XCTAssertEqual(Timeline.prompt(in: events), "Do the thing")
        let activity = Timeline.activity(from: events)
        XCTAssertEqual(activity.toolCalls, 3)
        XCTAssertEqual(activity.edits, 1)
        XCTAssertEqual(activity.commands, 1)
        let commands = Timeline.commands(in: items)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].command, "make test")
        XCTAssertEqual(commands[0].exitCode, 0)
    }
}

final class LineTailTests: XCTestCase {
    func testPartialLineIsHeldUntilComplete() {
        var tail = LineTail()
        var (from, reset) = tail.prepare(size: 10, fileID: 1)
        XCTAssertEqual(from, 0)
        XCTAssertFalse(reset)
        var step = tail.consume(Data("one\ntw".utf8), reset: reset)
        XCTAssertEqual(step.lines, ["one"])
        XCTAssertEqual(tail.offset, 4)

        (from, reset) = tail.prepare(size: 12, fileID: 1)
        XCTAssertEqual(from, 4)
        step = tail.consume(Data("two\nthree".utf8), reset: reset)
        XCTAssertEqual(step.lines, ["two"])
        XCTAssertEqual(tail.offset, 8)

        (from, _) = tail.prepare(size: 14, fileID: 1)
        step = tail.consume(Data("three\n".utf8), reset: false)
        XCTAssertEqual(step.lines, ["three"])
        XCTAssertEqual(tail.offset, 14)
    }

    func testTruncationAndReplacementRestartFromZero() {
        var tail = LineTail()
        _ = tail.prepare(size: 6, fileID: 1)
        _ = tail.consume(Data("a\nb\nc\n".utf8), reset: false)
        XCTAssertEqual(tail.offset, 6)
        var (from, reset) = tail.prepare(size: 2, fileID: 1)
        XCTAssertEqual(from, 0)
        XCTAssertTrue(reset, "shrank")
        _ = tail.consume(Data("x\n".utf8), reset: reset)
        (from, reset) = tail.prepare(size: 100, fileID: 2)
        XCTAssertEqual(from, 0)
        XCTAssertTrue(reset, "another inode")
    }

    func testOversizedLineDoesNotWedge() {
        var tail = LineTail(maxChunk: 4)
        _ = tail.prepare(size: 10, fileID: 1)
        let step = tail.consume(Data("abcd".utf8), reset: false)
        XCTAssertTrue(step.lines.isEmpty)
        XCTAssertTrue(step.more)
        XCTAssertEqual(tail.offset, 4)
    }

    func testChunkedReadsOverARealFile() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        var tail = LineTail(maxChunk: 8)
        XCTAssertNil(tail.read(path: path), "no file yet")
        FileManager.default.createFile(atPath: path, contents: Data("aaaa\nbbbb\ncc".utf8))
        var lines: [String] = []
        while let step = tail.read(path: path) {
            lines += step.lines
            if !step.more { break }
        }
        XCTAssertEqual(lines, ["aaaa", "bbbb"])
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("c\n".utf8))
        try handle.close()
        XCTAssertEqual(tail.read(path: path)?.lines, ["ccc"])
    }

    func testFileTailerDeliversAppendsAndIgnoresNonEvents() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data((eventLine(0, "task_started", #""prompt": "p""#) + "\n").utf8))
        let first = expectation(description: "initial")
        let second = expectation(description: "append")
        var received: [Int] = []
        let tailer = EventFileTailer(path: path) { events, _ in
            received += events.map(\.seq)
            if received == [0] { first.fulfill() }
            if received == [0, 1, 2] { second.fulfill() }
        }
        tailer.start()
        defer { tailer.stop() }
        wait(for: [first], timeout: 5)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        let appended = "garbage\n" + eventLine(1, "notice", #""text": "n""#) + "\n" + eventLine(2, "brand_new_kind") + "\n"
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        wait(for: [second], timeout: 5)
    }
}
