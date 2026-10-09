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
    let v1Kinds = [
        "task_started", "assistant_text", "assistant_delta", "tool_call", "tool_result",
        "user_message", "usage", "notice", "task_finished", "undelivered"
    ]

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

    // MARK: - assistant_delta / block-indexed assistant_text (Monitor piece 8)

    @Test
    func givenAnAssistantDeltaWithMessageIDAndBlockIndex_whenDecoded_thenBothAreExtracted() throws {
        // given / when
        let delta = try #require(TaskEvent(line: eventLine(
            0, "assistant_delta", #""message_id": "msg_1", "block_index": 2, "text": "ALPHA""#
        )))
        // then
        #expect(delta.kind == .assistantDelta(.init(messageID: "msg_1", blockIndex: 2, text: "ALPHA")))
    }

    @Test
    func givenAnAssistantDeltaWithNoMessageID_whenDecoded_thenItStillDecodesWithNilIdentity() throws {
        // given / when — a backend whose stream never disclosed a message/block id.
        let delta = try #require(TaskEvent(line: eventLine(0, "assistant_delta", #""text": "chunk""#)))
        // then
        #expect(delta.kind == .assistantDelta(.init(messageID: nil, blockIndex: nil, text: "chunk")))
    }

    @Test
    func givenAnAssistantTextWithMessageIDAndBlockIndex_whenDecoded_thenBothAreExtracted() throws {
        // given / when
        let text = try #require(TaskEvent(line: eventLine(
            0, "assistant_text", #""message_id": "msg_1", "block_index": 1, "text": "OMEGA""#
        )))
        // then
        #expect(text.kind == .assistantText(text: "OMEGA", messageID: "msg_1", blockIndex: 1))
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
    }

    // MARK: - Consumers of the new codex `file_change` / vibe `effect` tool_result emission

    // (Timeline/Parallel's success indicator, the Inspector's "Now" line, and activity counts are
    // all generic over `tool_call`/`tool_result` — these pin that genericity against the exact
    // shapes the two backends now emit, rather than assuming it).

    @Test
    func givenMultipleFileChangeEditsInOneCodexItem_whenBuildingTheTimeline_thenEachFileCountsOnceAndItsOwnResultFlipsIt() throws {
        // given — shaped exactly as codex's `file_change` normalizer emits: one tool_call/tool_result
        // pair per changed path, `call_id` = "<item id>:<path>".
        let events = [
            eventLine(0, "tool_call", #""call_id": "fc_1:a.swift", "tool": "file_change", "category": "edit", "input_preview": "{}", "path": "a.swift""#),
            eventLine(1, "tool_call", #""call_id": "fc_1:b.swift", "tool": "file_change", "category": "edit", "input_preview": "{}", "path": "b.swift""#),
            eventLine(2, "tool_result", #""call_id": "fc_1:a.swift", "ok": true, "output_tail": """#),
            eventLine(3, "tool_result", #""call_id": "fc_1:b.swift", "ok": false, "output_tail": "failed""#)
        ].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        let activity = Timeline.activity(from: events)
        // then — each changed file is its own row, merged with its own result — the exact read a
        // Timeline/Parallel row's success indicator makes.
        #expect(items.count == 2)
        guard case .tool(_, let resultA) = items[0].body, case .tool(_, let resultB) = items[1].body else {
            Issue.record("expected two .tool items"); return
        }
        #expect(resultA?.ok == true)
        #expect(resultB?.ok == false)
        // then — activity counts once per changed file, never once per `file_change` item.
        #expect(activity.toolCalls == 2)
        #expect(activity.edits == 2)
    }

    @Test
    func givenAToolResultWithNoPrecedingCall_whenComputingActivity_thenActivityCountsStayUnchanged() throws {
        // given — an orphan result (or one whose call the Timeline has not seen yet)
        let events = [
            eventLine(0, "tool_result", #""call_id": "zzz", "ok": true, "output_tail": "orphan""#)
        ].compactMap(TaskEvent.init(line:))
        // when
        let activity = Timeline.activity(from: events)
        // then — `Timeline.activity` switches on `.toolCall` alone, so a result-only stream leaves
        // every count at zero: results never move the Inspector's activity counts by themselves.
        #expect(activity.toolCalls == 0)
        #expect(activity.edits == 0)
        #expect(activity.commands == 0)
    }

    @Test
    func givenAVibeEffectShapedToolCallStillAwaitingItsResult_whenComputingCurrent_thenItIsTheInspectorsNow() throws {
        // given — a vibe `effect` normalizes to a `tool_call` with no `tool_result` until its
        // state settles; while that is true, it is the running tool the Inspector's "Now" shows.
        let events = [
            eventLine(0, "tool_call", #""call_id": "eff_1", "tool": "edit_file", "category": "edit", "input_preview": "{}", "path": "a.swift""#)
        ].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        // then
        #expect(Timeline.current(in: items)?.isRunningTool == true)
    }
}

// MARK: - Streaming timeline accumulation (Monitor piece 8)

@Suite
struct StreamingTimelineTests {
    private func delta(_ seq: Int, messageID: String? = "msg_1", blockIndex: Int? = 0, _ text: String) -> String {
        var fields = #""text": "\#(text)""#
        if let messageID { fields += #", "message_id": "\#(messageID)""# }
        if let blockIndex { fields += #", "block_index": \#(blockIndex)"# }
        return eventLine(seq, "assistant_delta", fields)
    }

    private func finalText(_ seq: Int, messageID: String? = "msg_1", blockIndex: Int? = 0, _ text: String) -> String {
        var fields = #""text": "\#(text)""#
        if let messageID { fields += #", "message_id": "\#(messageID)""# }
        if let blockIndex { fields += #", "block_index": \#(blockIndex)"# }
        return eventLine(seq, "assistant_text", fields)
    }

    @Test
    func givenChunksForTheSameBlock_whenBuildingTheTimeline_thenTheyAccumulateIntoOneInProgressItem() throws {
        // given
        let events = [delta(0, "AL"), delta(1, "PHA")].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        // then — one item, in place at the position of the first chunk, still marked streaming.
        #expect(items.count == 1)
        guard case .text(let text, let streaming) = items[0].body else { Issue.record("expected .text"); return }
        #expect(text == "ALPHA")
        #expect(streaming)
    }

    @Test
    func givenAFinalAssistantTextForTheSameBlock_whenBuildingTheTimeline_thenItReplacesTheInProgressItemInPlace() throws {
        // given — a tool call arrives between the deltas and the final text, so replacement must
        // still find the original item by (message_id, block_index), not by array position.
        let events = [
            delta(0, "AL"),
            eventLine(1, "tool_call", #""call_id": "c1", "tool": "Bash", "category": "shell", "input_preview": "{}""#),
            delta(2, "PHA"),
            finalText(3, "ALPHA")
        ].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        // then — no duplicate: still one text item, now final (not streaming), in its original slot.
        #expect(items.count == 2)
        guard case .text(let text, let streaming) = items[0].body else { Issue.record("expected .text at index 0"); return }
        #expect(text == "ALPHA")
        #expect(!streaming)
        guard case .tool = items[1].body else { Issue.record("expected .tool at index 1"); return }
    }

    @Test
    func givenTwoTextBlocksAroundAToolCall_whenBuildingTheTimeline_thenTheyStaySeparateAndOrdered() throws {
        // given — mirrors the real fixture (tests/fixtures/claude_partial_multiblock.jsonl): a text
        // block, then a tool call, then a second text block in the SAME message.
        let events = [
            delta(0, blockIndex: 1, "AL"), delta(1, blockIndex: 1, "PHA"),
            finalText(2, blockIndex: 1, "ALPHA"),
            eventLine(3, "tool_call", #""call_id": "c1", "tool": "Bash", "category": "shell", "input_preview": "{}""#),
            eventLine(4, "tool_result", #""call_id": "c1", "ok": true, "output_tail": "hi""#),
            delta(5, blockIndex: 3, "OME"), delta(6, blockIndex: 3, "GA"),
            finalText(7, blockIndex: 3, "OMEGA")
        ].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        // then — three items, in order, each block's text final and un-duplicated.
        #expect(items.count == 3)
        guard case .text(let first, false) = items[0].body else { Issue.record("expected first text"); return }
        #expect(first == "ALPHA")
        guard case .tool = items[1].body else { Issue.record("expected the tool call"); return }
        guard case .text(let second, false) = items[2].body else { Issue.record("expected second text"); return }
        #expect(second == "OMEGA")
    }

    @Test
    func givenDeltasWithNoMessageID_whenBuildingTheTimeline_thenEachIsItsOwnStandaloneIncompleteItem() throws {
        // given — Review round 1, item 2: an id-less delta is never merged into anything.
        let events = [
            delta(0, messageID: nil, blockIndex: nil, "one"),
            delta(1, messageID: nil, blockIndex: nil, "two")
        ].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        // then — two separate items, not one accumulated "onetwo".
        #expect(items.count == 2)
        guard case .text(let first, true) = items[0].body else { Issue.record("expected streaming text"); return }
        #expect(first == "one")
        guard case .text(let second, true) = items[1].body else { Issue.record("expected streaming text"); return }
        #expect(second == "two")
    }

    @Test
    func givenADeltaStreamWithNoFinalMessage_whenBuildingTheTimeline_thenWhatArrivedShowsMarkedIncomplete() throws {
        // given — the task ended (or was cancelled) mid-message: deltas arrived, no final assistant_text.
        let events = [delta(0, "Look"), delta(1, "ing…")].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        // then
        #expect(items.count == 1)
        guard case .text(let text, let streaming) = items[0].body else { Issue.record("expected .text"); return }
        #expect(text == "Looking…")
        #expect(streaming, "an unterminated stream stays marked incomplete")
    }

    @Test
    func givenAFinalTextWithNoPrecedingDeltas_whenBuildingTheTimeline_thenItAppearsAsAnOrdinaryCompleteItem() throws {
        // given — a backend with no partial stream (codex/opencode/vibe), or claude without
        // `--include-partial-messages`: the final text carries no matching in-progress item.
        let events = [finalText(0, messageID: nil, blockIndex: nil, "Done.")].compactMap(TaskEvent.init(line:))
        // when
        let items = Timeline.items(from: events)
        // then
        #expect(items.count == 1)
        guard case .text(let text, let streaming) = items[0].body else { Issue.record("expected .text"); return }
        #expect(text == "Done.")
        #expect(!streaming)
    }

    @Test
    func givenAFiveThousandChunkStream_whenBuildingTheTimeline_thenItCompletesWellUnderASecond() {
        // given — accumulation must be an O(1) dictionary lookup per delta, never a rescan of
        // `items`, or a long stream turns quadratic.
        let events = (0 ..< 5000).map { delta($0, "x") }.compactMap(TaskEvent.init(line:))
        // when
        let start = Date()
        let items = Timeline.items(from: events)
        let elapsed = Date().timeIntervalSince(start)
        // then
        #expect(items.count == 1)
        guard case .text(let text, true) = items[0].body else { Issue.record("expected one streaming item"); return }
        #expect(text.count == 5000)
        #expect(elapsed < 1.0, "took \(elapsed)s for 5,000 chunks")
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
    func givenExhaustedTailer_whenQueuedOlderRequestIsDeclined_thenCurrentHistoryAcknowledgesCompletion() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        try Data((eventLine(0, "notice", #""text":"synthetic""#) + "\n").utf8).write(to: URL(fileURLWithPath: path))
        var histories: [EventHistoryState] = []
        let tailer = EventFileTailer(path: path, historyHandler: { histories.append($0) }) { _, _, _ in }
        tailer.start()
        defer { tailer.stop() }
        #expect(await waitUntil { histories.last?.isLoading == false && histories.last?.hasMore == false })
        let count = histories.count
        tailer.loadMore()
        #expect(await waitUntil { histories.count > count })
        #expect(histories.last?.isLoading == false)
        #expect(histories.last?.hasMore == false)
        #expect(histories.last?.error == nil)
    }

    @Test @MainActor
    func givenAFileBeingAppendedTo_whenTailed_thenDeliveriesArriveInOrderAndIgnoreNonEvents() async throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data((eventLine(0, "task_started", #""prompt": "p""#) + "\n").utf8))
        var received: [Int] = []
        let tailer = EventFileTailer(path: path) { events, _, _ in
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

    // MARK: - EventAvailability (the Summary tab's "Files the agent edited" section needs to tell

    // "nothing has happened yet" apart from "there is no log to read at all")

    @Test @MainActor
    func givenAFileThatNeverAppears_whenTailed_thenAvailabilityReportsUnavailable() async throws {
        // given — a path in a real (removed) directory, so the tailer's very first read fails to open it.
        let dir = try makeTempDir()
        try FileManager.default.removeItem(at: dir)
        let path = dir.appendingPathComponent("t.events.jsonl").path
        var seen: [EventAvailability] = []
        let tailer = EventFileTailer(path: path) { _, _, availability in seen.append(availability) }
        // when
        tailer.start()
        defer { tailer.stop() }
        // then
        let sawUnavailable = await waitUntil { seen.last == .unavailable }
        #expect(sawUnavailable, "seen so far: \(seen)")
    }

    @Test @MainActor
    func givenAFileCreatedAfterTailingStarts_whenItAppears_thenAvailabilityMovesFromUnavailableToAvailable() async throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        var seen: [EventAvailability] = []
        let tailer = EventFileTailer(path: path) { _, _, availability in seen.append(availability) }
        tailer.start()
        defer { tailer.stop() }
        let sawUnavailable = await waitUntil { seen.last == .unavailable }
        #expect(sawUnavailable, "seen so far: \(seen)")
        // when
        FileManager.default.createFile(atPath: path, contents: Data((eventLine(0, "notice", #""text": "n""#) + "\n").utf8))
        // then
        let sawAvailable = await waitUntil { seen.last == .available }
        #expect(sawAvailable, "seen so far: \(seen)")
    }

    @Test @MainActor
    func givenAnUnreadableFile_whenTailed_thenAvailabilityReportsUnavailable() async throws {
        // given — present on disk but with no read permission, so `open()` itself fails (EACCES),
        // the same "could not open at all" path a missing file takes.
        let dir = try makeTempDir()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dir.appendingPathComponent("t.events.jsonl").path)
            try? FileManager.default.removeItem(at: dir)
        }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data("garbage".utf8), attributes: [.posixPermissions: 0o000])
        var seen: [EventAvailability] = []
        let tailer = EventFileTailer(path: path) { _, _, availability in seen.append(availability) }
        // when
        tailer.start()
        defer { tailer.stop() }
        // then
        let sawUnavailable = await waitUntil { seen.last == .unavailable }
        #expect(sawUnavailable, "seen so far: \(seen)")
    }

    @Test @MainActor
    func givenAnAlreadyExistingFile_whenTailingStarts_thenTheFirstReportIsAvailableNotLoading() async throws {
        // given — `.loading` is the tailer's initial in-memory state before any read has been
        // attempted; the very first drain must resolve it one way or the other rather than leaving
        // a caller to infer availability from an empty event list.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data((eventLine(0, "notice", #""text": "n""#) + "\n").utf8))
        var seen: [EventAvailability] = []
        let tailer = EventFileTailer(path: path) { _, _, availability in seen.append(availability) }
        // when
        tailer.start()
        defer { tailer.stop() }
        // then
        let sawAvailable = await waitUntil { !seen.isEmpty }
        #expect(sawAvailable, "seen so far: \(seen)")
        #expect(seen.first == .available, "the first report must never be .loading: \(seen)")
    }
}
