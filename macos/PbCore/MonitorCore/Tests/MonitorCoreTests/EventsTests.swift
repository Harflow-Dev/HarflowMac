import Foundation
@testable import MonitorCore
import Testing

/// Lines shaped exactly as `events.EventLog.write` produces them.
func eventLine(_ seq: Int, _ kind: String, _ fields: String = "") -> String {
    let extra = fields.isEmpty ? "" : ", " + fields
    return #"{"v": 1, "seq": \#(seq), "observed_at": "2026-09-25T01:00:\#(String(format: "%02d", seq % 60)).000000+00:00", "source_ts": null, "#
        + #""raw_offset": null, "task_id": "t1", "kind": "\#(kind)"\#(extra)}"#
}

@Suite
struct EventDecodingTests {
    /// Every kind in `events.EVENT_KINDS` (src/polybridge/events.py). If that set grows, this
    /// list and `TaskEvent.Kind` grow with it — the frozen v1 contract.
    let v1Kinds = ["task_started", "assistant_text", "tool_call", "tool_result", "user_message", "usage", "notice", "task_finished", "undelivered"]

    @Test
    func givenEveryV1Kind_whenDecoded_thenEachHasItsOwnCase() {
        // given / when / then
        for (index, kind) in v1Kinds.enumerated() {
            let event = TaskEvent(line: eventLine(index, kind))
            #expect(event != nil, "\(kind)")
            #expect(event!.isUnknown == false, "\(kind) must not be .unknown")
        }
    }

    @Test
    func givenEventLinesWithFields_whenDecoded_thenTheFieldsAreExtracted() throws {
        // given / when
        let started = try #require(TaskEvent(line: eventLine(
            0, "task_started",
            #""backend": "claude", "freedom": "read_only", "prompt": "Fix it\nplease", "#
                + #""reasoning_effort": "high", "spawned_by": "p", "live_input": true"#
        )))
        guard case .taskStarted(let startedFields) = started.kind else { Issue.record("expected .taskStarted"); return }
        // then
        #expect(startedFields.prompt == "Fix it\nplease")
        #expect(startedFields.reasoningEffort == "high")
        #expect(startedFields.spawnedBy == "p")
        #expect(startedFields.liveInput == true)
        #expect(started.seq == 0)
        #expect(started.observedAt != nil)

        let call = try #require(TaskEvent(line: eventLine(
            1, "tool_call",
            #""call_id": "c1", "tool": "Edit", "category": "edit", "input_preview": "{}", "#
                + #""path": "/r/a.swift", "edit": {"old": "a", "new": "b"}"#
        )))
        guard case .toolCall(let toolCallFields) = call.kind else { Issue.record("expected .toolCall"); return }
        #expect(toolCallFields.path == "/r/a.swift")
        #expect(toolCallFields.editOld == "a")
        #expect(toolCallFields.editNew == "b")
        #expect(toolCallFields.headline == "/r/a.swift")

        let result = try #require(TaskEvent(line: eventLine(2, "tool_result", #""call_id": "c1", "ok": false, "output_tail": "boom", "exit_code": 2"#)))
        #expect(result.kind == .toolResult(.init(callID: "c1", ok: false, outputTail: "boom", exitCode: 2)))

        let message = try #require(TaskEvent(line: eventLine(3, "user_message", #""text": "more", "source": "injected", "message_id": "m1""#)))
        #expect(message.kind == .userMessage(text: "more", source: "injected", messageID: "m1"))

        let undelivered = try #require(TaskEvent(line: eventLine(4, "undelivered", #""message_id": "m2", "text": "late", "reason": "closed""#)))
        #expect(undelivered.kind == .undelivered(messageID: "m2", text: "late", reason: "closed"))

        let finished = try #require(TaskEvent(line: eventLine(
            5, "task_finished", #""status": "completed", "exit_code": 0, "summary": "ok", "observed": true"#
        )))
        #expect(finished.kind == .taskFinished(status: "completed", exitCode: 0, summary: "ok", observed: true))
    }

    @Test
    func givenAnUnknownKind_whenDecoded_thenItIsKeptAsUnknownAndIgnoredByTheTimeline() throws {
        // given / when
        let event = try #require(TaskEvent(line: eventLine(0, "future_kind", #""x": 1"#)))
        // then
        #expect(event.kind == .unknown("future_kind"))
        #expect(Timeline.items(from: [event]).isEmpty)
    }

    @Test
    func givenMalformedOrWrongVersionLines_whenDecoded_thenNoneProduceAnEvent() {
        // given / when / then
        #expect(TaskEvent(line: "not json") == nil)
        #expect(TaskEvent(line: #"{"v": 2, "seq": 0, "kind": "notice"}"#) == nil, "another schema version is not read")
        #expect(TaskEvent(line: #"{"v": 1, "seq": 0}"#) == nil)
        #expect(TaskEvent(line: "[1,2]") == nil)
    }

    @Test
    func givenAMixOfCallsAndResults_whenBuildingTheTimeline_thenResultsMergeIntoTheirCalls() throws {
        // given
        let events = [
            eventLine(0, "task_started", #""prompt": "Do the thing""#),
            eventLine(1, "assistant_text", #""text": "Looking""#),
            eventLine(2, "assistant_text", #""text": "   ""#),
            eventLine(3, "tool_call", #""call_id": "a", "tool": "Bash", "category": "shell", "input_preview": "{}", "command": "make test""#),
            eventLine(4, "tool_call", #""call_id": "b", "tool": "Read", "category": "read", "input_preview": "{}", "path": "x""#),
            eventLine(5, "tool_result", #""call_id": "a", "ok": true, "output_tail": "ok", "exit_code": 0"#),
            eventLine(6, "tool_result", #""call_id": "zzz", "ok": true, "output_tail": "orphan""#),
            eventLine(7, "usage", #""total_cost_usd": 0.1, "num_turns": 1"#),
            eventLine(8, "tool_call", #""call_id": "c", "tool": "Edit", "category": "edit", "input_preview": "{}""#)
        ].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        // then
        #expect(items.map(\.id) == [0, 1, 3, 4, 8])
        guard case .tool(let call, let result) = items[2].body else { Issue.record("expected .tool"); return }
        #expect(call.command == "make test")
        #expect(result?.exitCode == 0)
        #expect(Timeline.current(in: items)?.id == 8, "the latest call without a result is what is happening now")
        #expect(Timeline.prompt(in: events) == "Do the thing")
        let activity = Timeline.activity(from: events)
        #expect(activity.toolCalls == 3)
        #expect(activity.edits == 1)
        #expect(activity.commands == 1)
        let commands = Timeline.commands(in: items)
        #expect(commands.count == 1)
        #expect(commands[0].command == "make test")
        #expect(commands[0].exitCode == 0)
    }
}

@Suite
struct LineTailTests {
    @Test
    func givenAPartialLine_whenConsumed_thenItIsHeldUntilComplete() {
        // given
        var tail = LineTail()
        // when
        var (from, reset) = tail.prepare(size: 10, fileID: 1)
        // then
        #expect(from == 0)
        #expect(!reset)
        var step = tail.consume(Data("one\ntw".utf8), reset: reset)
        #expect(step.lines == ["one"])
        #expect(tail.offset == 4)

        (from, reset) = tail.prepare(size: 12, fileID: 1)
        #expect(from == 4)
        step = tail.consume(Data("two\nthree".utf8), reset: reset)
        #expect(step.lines == ["two"])
        #expect(tail.offset == 8)

        (from, _) = tail.prepare(size: 14, fileID: 1)
        step = tail.consume(Data("three\n".utf8), reset: false)
        #expect(step.lines == ["three"])
        #expect(tail.offset == 14)
    }

    @Test
    func givenAShrunkOrReplacedFile_whenPrepared_thenItRestartsFromZero() {
        // given
        var tail = LineTail()
        _ = tail.prepare(size: 6, fileID: 1)
        _ = tail.consume(Data("a\nb\nc\n".utf8), reset: false)
        #expect(tail.offset == 6)
        // when
        var (from, reset) = tail.prepare(size: 2, fileID: 1)
        // then
        #expect(from == 0)
        #expect(reset, "shrank")
        _ = tail.consume(Data("x\n".utf8), reset: reset)
        (from, reset) = tail.prepare(size: 100, fileID: 2)
        #expect(from == 0)
        #expect(reset, "another inode")
    }

    @Test
    func givenASameInodeTruncateAndRegrow_whenRead_thenItIsDetectedAsAReset() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data("first-a\nfirst-b\n".utf8))
        var tail = LineTail()
        #expect(tail.read(path: path)?.lines == ["first-a", "first-b"])
        // Same inode: truncate in place, then write more than was there before.
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data("second-a\nsecond-b\nsecond-c\n".utf8))
        try handle.close()
        // when
        guard let step = tail.read(path: path) else { Issue.record("expected a step"); return }
        // then
        #expect(step.reset, "the bytes before the offset changed")
        #expect(step.lines == ["second-a", "second-b", "second-c"])
    }

    @Test
    func givenPlainAppends_whenRead_thenTheyAreNotMistakenForARewrite() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data("one\n".utf8))
        var tail = LineTail()
        _ = tail.read(path: path)
        // when / then
        for n in 2 ... 40 {
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("line-\(n)\n".utf8))
            try handle.close()
            guard let step = tail.read(path: path) else { Issue.record("expected a step"); return }
            #expect(!step.reset)
            #expect(step.lines == ["line-\(n)"])
        }
    }

    @Test
    func givenALineLargerThanTheChunk_whenConsumed_thenItDoesNotWedge() {
        // given
        var tail = LineTail(maxChunk: 4)
        _ = tail.prepare(size: 10, fileID: 1)
        // when
        let step = tail.consume(Data("abcd".utf8), reset: false)
        // then
        #expect(step.lines.isEmpty)
        #expect(step.more)
        #expect(tail.offset == 4)
    }

    @Test
    func givenARealFileReadInSmallChunks_whenRead_thenLinesArriveWholeAcrossChunks() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        var tail = LineTail(maxChunk: 8)
        // when / then
        #expect(tail.read(path: path) == nil, "no file yet")
        FileManager.default.createFile(atPath: path, contents: Data("aaaa\nbbbb\ncc".utf8))
        var lines: [String] = []
        while let step = tail.read(path: path) {
            lines += step.lines
            if !step.more { break }
        }
        #expect(lines == ["aaaa", "bbbb"])
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("c\n".utf8))
        try handle.close()
        #expect(tail.read(path: path)?.lines == ["ccc"])
    }

    @Test @MainActor
    func givenAFileBeingAppendedTo_whenTailed_thenDeliveriesArriveInOrderAndIgnoreNonEvents() async throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data((eventLine(0, "task_started", #""prompt": "p""#) + "\n").utf8))
        var received: [Int] = []
        let tailer = EventFileTailer(path: path) { events, _ in
            received += events.map(\.seq)
        }
        tailer.start()
        defer { tailer.stop() }
        // when
        let sawFirst = await waitUntil { received == [0] }
        #expect(sawFirst, "received so far: \(received)")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        let appended = "garbage\n" + eventLine(1, "notice", #""text": "n""#) + "\n" + eventLine(2, "brand_new_kind") + "\n"
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        let sawSecond = await waitUntil { received == [0, 1, 2] }
        // then
        #expect(sawSecond, "received so far: \(received)")
    }
}
