import Foundation
@testable import MonitorCore
import Testing

// MARK: - TimelineBuilder (Codex review round 1 on Monitor piece 8's performance findings)

@Suite
struct TimelineBuilderTests {
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

    /// A representative stream: two blocks with an interleaved tool call, exercising every merge
    /// path `TimelineBuilder`/`Timeline.items(from:)` document — deltas, a final replace, tool
    /// call/result pairing, and a plain notice.
    private func mixedEvents() -> [TaskEvent] {
        [
            eventLine(0, "task_started", #""prompt": "Do the thing""#),
            delta(1, blockIndex: 1, "AL"), delta(2, blockIndex: 1, "PHA"),
            finalText(3, blockIndex: 1, "ALPHA"),
            eventLine(4, "tool_call", #""call_id": "c1", "tool": "Bash", "category": "shell", "input_preview": "{}""#),
            eventLine(5, "tool_result", #""call_id": "c1", "ok": true, "output_tail": "hi""#),
            eventLine(6, "notice", #""text": "n""#),
            delta(7, blockIndex: 3, "OME"), delta(8, blockIndex: 3, "GA"),
            finalText(9, blockIndex: 3, "OMEGA")
        ].compactMap(TaskEvent.init(line:))
    }

    @Test
    func givenEventsAppendedInSeveralSmallBatches_whenComparedToOneShotItems_thenTheyAreIdentical() {
        // given — split at arbitrary, uneven points, including mid-way through a streaming block.
        let events = mixedEvents()
        let batches = [Array(events[0 ..< 1]), Array(events[1 ..< 3]), Array(events[3 ..< 4]), Array(events[4 ..< 6]), Array(events[6...])]
        // when
        var builder = TimelineBuilder()
        for batch in batches { builder.append(batch) }
        // then
        #expect(builder.items == Timeline.items(from: events))
    }

    @Test
    func givenEventsAppendedOneAtATime_whenComparedToOneShotItems_thenTheyAreIdentical() {
        // given — the extreme case of "several batches": one event per `append` call.
        let events = mixedEvents()
        // when
        var builder = TimelineBuilder()
        for event in events { builder.append([event]) }
        // then
        #expect(builder.items == Timeline.items(from: events))
    }

    @Test
    func givenABuilderDiscardedAfterAReset_whenAFreshBuilderAppendsNewEvents_thenOnlyTheFreshEventsShow() {
        // given — mirrors what `EventStreamRepositoryImpl` does on a tailer reset: replace the
        // builder outright rather than teaching it to forget what it already built.
        let staleEvents = [eventLine(0, "task_started", #""prompt": "stale""#), delta(1, "STALE")].compactMap(TaskEvent.init(line:))
        var builder = TimelineBuilder()
        builder.append(staleEvents)
        #expect(!builder.items.isEmpty)

        // when — reset: a fresh builder, never told about `staleEvents` again.
        let freshEvents = [eventLine(0, "task_started", #""prompt": "fresh""#), delta(1, messageID: "m2", "FRESH")].compactMap(TaskEvent.init(line:))
        builder = TimelineBuilder()
        builder.append(freshEvents)

        // then — identical to a one-shot build of the fresh events alone.
        #expect(builder.items == Timeline.items(from: freshEvents))
        #expect(!builder.items.contains { if case .text(let text, _) = $0.body { return text.contains("STALE") }; return false })
    }

    @Test
    func given200AppendCallsOf50NewEventsEach_whenBuildingIncrementally_thenItCompletesWellUnderASecond() {
        // given — Codex review round 1, finding 1: `EventStreamRepositoryImpl` calls `append` once
        // per flush with only that flush's NEW events, never the whole history. 200 flushes of 50
        // events each (10,000 total) is that exact call pattern; each `append` call only ever
        // touches what it is handed, so the total cost across every call stays O(total events),
        // never O(flushes × events-so-far). Decoding the fixture lines is done up front, outside the
        // timed section — this measures `append`'s own cost, not `TaskEvent(line:)`'s JSON parsing.
        let batches: [[TaskEvent]] = (0 ..< 200).map { flush in
            (0 ..< 50).map { offset in eventLine(flush * 50 + offset, "notice", #""text": "n""#) }.compactMap(TaskEvent.init(line:))
        }
        var builder = TimelineBuilder()
        // when
        let start = Date()
        for batch in batches { builder.append(batch) }
        let elapsed = Date().timeIntervalSince(start)
        let items = builder.items
        // then
        #expect(items.count == 10000)
        #expect(elapsed < 1.0, "took \(elapsed)s for 200 flushes of 50 events each")
    }

    @Test
    func givenTwentyThousandChunksForOneBlock_whenAppendedAcrossManyCalls_thenItStaysFastAndJoinsCorrectlyOnlyWhenRead() {
        // given — Codex review round 1, finding 2: a chunk must never copy the whole accumulated
        // text so far. 20,000 chunks of ~8 characters, appended across many separate calls (as real
        // flushes would), is the adversarial case for exactly one streaming block. Decoding is done
        // up front, outside the timed section, for the same reason as above.
        let chunkText = "12345678"
        let events = (0 ..< 20000).map { delta($0, chunkText) }.compactMap(TaskEvent.init(line:))
        var builder = TimelineBuilder()
        // when
        let start = Date()
        for event in events { builder.append([event]) }
        let elapsed = Date().timeIntervalSince(start)
        // the join happens once, only here, at read time.
        let items = builder.items
        // then
        #expect(items.count == 1)
        guard case .text(let text, true) = items[0].body else { Issue.record("expected one streaming item"); return }
        #expect(text.count == 20000 * chunkText.count)
        #expect(elapsed < 1.0, "took \(elapsed)s for 20,000 chunks of one block")
    }

    // MARK: - Copy-on-write isolation (Codex review round 2, finding 1)

    // `TimelineBuilder` is a value type, but its in-progress streaming text is held in a class-typed
    // `ChunkBuffer` for O(1) chunk appends (finding 2 above) — without its own copy-on-write
    // isolation, a struct copy would leave both copies' `.streamingText` entries pointing at the
    // SAME buffer, so appending through either copy would silently leak into the other's `items`.

    @Test
    func givenABuilderIsCopiedAndTheCopyAppendsMoreDeltas_whenReadingItems_thenTheOriginalIsUnaffected() {
        // given — one chunk appended before the copy is taken.
        var original = TimelineBuilder()
        original.append([delta(0, "AL")].compactMap(TaskEvent.init(line:)))
        var copy = original

        // when — only the COPY keeps streaming.
        copy.append([delta(1, "PHA")].compactMap(TaskEvent.init(line:)))

        // then — the original's own in-progress text is untouched by the copy's later append.
        guard case .text(let originalText, true) = original.items[0].body else { Issue.record("expected streaming text"); return }
        guard case .text(let copyText, true) = copy.items[0].body else { Issue.record("expected streaming text"); return }
        #expect(originalText == "AL")
        #expect(copyText == "ALPHA")
    }

    @Test
    func givenABuilderIsCopiedAndTheOriginalAppendsMoreDeltas_whenReadingItems_thenTheCopyIsUnaffected() {
        // given — one chunk appended before the copy is taken.
        var original = TimelineBuilder()
        original.append([delta(0, "AL")].compactMap(TaskEvent.init(line:)))
        let copy = original

        // when — only the ORIGINAL keeps streaming (the reverse direction from the test above).
        original.append([delta(1, "PHA")].compactMap(TaskEvent.init(line:)))

        // then — the copy's own in-progress text is untouched by the original's later append.
        guard case .text(let originalText, true) = original.items[0].body else { Issue.record("expected streaming text"); return }
        guard case .text(let copyText, true) = copy.items[0].body else { Issue.record("expected streaming text"); return }
        #expect(originalText == "ALPHA")
        #expect(copyText == "AL")
    }

    @Test
    func givenABuilderIsCopiedSeveralTimes_whenEachCopyAppendsIndependently_thenEveryCopyStaysIsolated() {
        // given — three independent branches from the same starting point, mirroring several
        // `TimelineBuilder`s ever being handed the same starting state (defensive: this codebase
        // only ever holds one builder per task today, but the type itself must not assume that).
        var base = TimelineBuilder()
        base.append([delta(0, "A")].compactMap(TaskEvent.init(line:)))
        var branchOne = base
        var branchTwo = base

        // when
        branchOne.append([delta(1, "-one")].compactMap(TaskEvent.init(line:)))
        branchTwo.append([delta(1, "-two")].compactMap(TaskEvent.init(line:)))
        base.append([delta(1, "-base")].compactMap(TaskEvent.init(line:)))

        // then — each branch, including the original `base`, only ever saw its own appends.
        func text(_ builder: TimelineBuilder) -> String {
            guard case .text(let text, true) = builder.items[0].body else { return "<not streaming>" }
            return text
        }
        #expect(text(base) == "A-base")
        #expect(text(branchOne) == "A-one")
        #expect(text(branchTwo) == "A-two")
    }
}
