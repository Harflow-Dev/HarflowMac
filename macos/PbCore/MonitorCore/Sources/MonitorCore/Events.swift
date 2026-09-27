import Foundation

/// The one `"v"` this app understands for `events.jsonl` lines — a contract separate from
/// `polybridge-ctl`'s (`ctlContractVersions`, `CtlModels.swift`) and `polybridge-setup`'s
/// (`setupContractVersion`, `SetupClient.swift`), so a shape change to one never silently widens
/// what the app accepts from the others. A line at any other version simply fails to decode
/// (`TaskEvent.init?` returns nil), the same as any other malformed line — a new event kind, not a
/// new log version, is how the log stays readable by an older app (see `EVENT_KINDS`).
public let eventLogVersion = 1

/// One line of `<task_id>.events.jsonl`, schema v1 (README "The normalized event log").
/// The kind set mirrors `events.EVENT_KINDS`; anything else decodes as `.unknown` and is ignored.
public struct TaskEvent: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        case taskStarted(TaskStarted)
        /// `messageID`/`blockIndex` identify the content block the text came from — present only
        /// when the backend's own stream disclosed them (claude's partial-message stream) — so a
        /// matching in-progress `assistant_delta` accumulation can be replaced by this final text.
        case assistantText(text: String, messageID: String?, blockIndex: Int?)
        /// One streamed chunk of claude text (the chunk only, never cumulative), keyed by the
        /// `(messageID, blockIndex)` its final `assistantText` will carry. `messageID`/`blockIndex`
        /// are nil when the backend's stream did not disclose them, in which case the chunk is
        /// never merged with anything else (Review round 1, item 2).
        case assistantDelta(AssistantDelta)
        case toolCall(ToolCall)
        case toolResult(ToolResult)
        case userMessage(text: String, source: String?, messageID: String?)
        case usage(totalCostUSD: Double?, numTurns: Int?)
        case notice(String)
        case taskFinished(status: String, exitCode: Int?, summary: String?, observed: Bool?)
        case undelivered(messageID: String?, text: String?, reason: String?)
        case unknown(String)
    }

    public struct TaskStarted: Equatable, Sendable {
        public let backend: String?
        public let freedom: String?
        public let repoPath: String?
        public let prompt: String
        public let model: String?
        public let reasoningEffort: String?
        public let spawnedBy: String?
        public let group: String?
        public let liveInput: Bool?
    }

    public struct AssistantDelta: Equatable, Sendable {
        public let messageID: String?
        public let blockIndex: Int?
        public let text: String
    }

    public struct ToolCall: Equatable, Sendable {
        public let callID: String
        public let tool: String
        public let category: String
        public let inputPreview: String
        public let path: String?
        public let command: String?
        public let editOld: String?
        public let editNew: String?
    }

    public struct ToolResult: Equatable, Sendable {
        public let callID: String
        public let ok: Bool
        public let outputTail: String
        public let exitCode: Int?
    }

    public var id: Int { seq }
    public let seq: Int
    public let observedAt: Date?
    public let sourceTimestamp: Date?
    public let kind: Kind
    /// The line exactly as written, for the Raw events tab.
    public let rawLine: String

    public var timestamp: Date? { observedAt ?? sourceTimestamp }

    public var isUnknown: Bool {
        if case .unknown = kind { return true }
        return false
    }

    /// nil for a line that is not a v1 event at all (not JSON, no `kind`, another `v`).
    public init?(line: String) {
        guard let object = JSONValue.parse(Data(line.utf8))?.objectValue,
              object["v"]?.intValue == eventLogVersion,
              let kindName = object["kind"]?.stringValue else { return nil }
        rawLine = line
        seq = object["seq"]?.intValue ?? -1
        observedAt = object["observed_at"]?.stringValue.flatMap(ISODate.parse)
        sourceTimestamp = object["source_ts"]?.stringValue.flatMap(ISODate.parse)
        let s = { (key: String) in object[key]?.stringValue }
        switch kindName {
        case "task_started":
            kind = .taskStarted(TaskStarted(
                backend: s("backend"), freedom: s("freedom"), repoPath: s("repo_path"),
                prompt: s("prompt") ?? "", model: s("model"), reasoningEffort: s("reasoning_effort"),
                spawnedBy: s("spawned_by"), group: s("group"), liveInput: object["live_input"]?.boolValue
            ))
        case "assistant_text":
            kind = .assistantText(text: s("text") ?? "", messageID: s("message_id"), blockIndex: object["block_index"]?.intValue)
        case "assistant_delta":
            kind = .assistantDelta(AssistantDelta(
                messageID: s("message_id"), blockIndex: object["block_index"]?.intValue, text: s("text") ?? ""
            ))
        case "tool_call":
            let edit = object["edit"]?.objectValue
            kind = .toolCall(ToolCall(
                callID: s("call_id") ?? "", tool: s("tool") ?? "tool", category: s("category") ?? "other",
                inputPreview: s("input_preview") ?? "", path: s("path"), command: s("command"),
                editOld: edit?["old"]?.stringValue, editNew: edit?["new"]?.stringValue
            ))
        case "tool_result":
            kind = .toolResult(ToolResult(
                callID: s("call_id") ?? "", ok: object["ok"]?.boolValue ?? true,
                outputTail: s("output_tail") ?? "", exitCode: object["exit_code"]?.intValue
            ))
        case "user_message":
            kind = .userMessage(text: s("text") ?? "", source: s("source"), messageID: s("message_id"))
        case "usage":
            kind = .usage(totalCostUSD: object["total_cost_usd"]?.doubleValue, numTurns: object["num_turns"]?.intValue)
        case "notice":
            kind = .notice(s("text") ?? "")
        case "task_finished":
            kind = .taskFinished(status: s("status") ?? "unknown", exitCode: object["exit_code"]?.intValue, summary: s("summary"), observed: object["observed"]?.boolValue)
        case "undelivered":
            kind = .undelivered(messageID: s("message_id"), text: s("text"), reason: s("reason"))
        default:
            kind = .unknown(kindName)
        }
    }
}

/// What the timeline shows: a tool call merged with its result, everything else one row each.
public struct TimelineItem: Equatable, Identifiable, Sendable {
    public enum Body: Equatable, Sendable {
        case started(TaskEvent.TaskStarted)
        /// `streaming` is true for an in-progress `assistant_delta` accumulation that has not (yet,
        /// or ever) been replaced by its final `assistant_text` — the Monitor shows a caret while
        /// the owning turn is still running, and an "(incomplete)" label once it is not.
        case text(String, streaming: Bool)
        case tool(TaskEvent.ToolCall, TaskEvent.ToolResult?)
        case message(text: String, source: String?)
        case notice(String)
        case undelivered(text: String?, reason: String?)
        case finished(status: String, exitCode: Int?, summary: String?)
    }

    public let id: Int
    public let at: Date?
    public let body: Body

    public var isRunningTool: Bool {
        if case .tool(_, nil) = body { return true }
        return false
    }
}

public struct ActivityCounts: Equatable, Sendable {
    public var toolCalls = 0
    public var edits = 0
    public var commands = 0
    public init() {}
}

/// Identifies one streamed content block across its `assistant_delta` chunks and its final
/// `assistant_text` — Review round 1, item 2. Both halves must be present to merge; a delta or
/// final text missing either half is never merged with anything (handled inline, not through this
/// key).
private struct DeltaKey: Hashable {
    let messageID: String
    let blockIndex: Int
}

/// Incremental, stateful timeline construction (Codex review round 1 on Monitor piece 8's
/// performance: `EventStreamRepositoryImpl` used to call `Timeline.items(from: allEventsSoFar)` on
/// every flush, reprocessing the WHOLE history each time — O(n²) total over a long stream).
/// `append(_:)` extends whatever state earlier calls already built, touching only the events handed
/// to it; `items` reads the current materialized snapshot. A caller that needs a full rebuild (a
/// tailer reset, or a one-shot conversion — see `Timeline.items(from:)` below) simply starts a fresh
/// `TimelineBuilder` and appends into it, rather than the builder needing its own reset method.
///
/// Mirrors the pairing rules `Timeline.items(from:)` documented: `tool_result` merges into its
/// `tool_call` by `call_id`; `assistant_delta` chunks accumulate by `(message_id, block_index)` into
/// one in-progress item, replaced in place by the matching final `assistant_text` (final text wins,
/// no duplicate); a delta or final text missing either half of that id is never merged with
/// anything; `usage` and unknown kinds are dropped.
public struct TimelineBuilder: Sendable {
    /// Holds one streaming block's chunks by reference so appending to it never copies the
    /// accumulated array via `entries`' own copy-on-write (Codex review round 1, finding 2: a chunk
    /// must never trigger an O(current length) copy). Mutated only while the owner holds whatever
    /// lock serializes its own calls into this builder — see `EventStreamRepositoryImpl`'s
    /// `bufferLock`, which now spans the whole apply, not just the buffer drain.
    private final class ChunkBuffer: @unchecked Sendable {
        var chunks: [String] = []
    }

    private enum Entry {
        case item(TimelineItem)
        case streamingText(id: Int, timestamp: Date?, buffer: ChunkBuffer)
        /// Transient — used only inside `appendDelta`'s isolation dance below, to detach `entries`'
        /// own strong reference to a `ChunkBuffer` for the instant it takes to check
        /// `isKnownUniquelyReferenced`. Every code path that writes this also overwrites it before
        /// returning; nothing else in this type ever produces or reads it.
        case placeholder
    }

    private var entries: [Entry] = []
    private var callIndex: [String: Int] = [:]
    private var deltaIndex: [DeltaKey: Int] = [:]

    public init() {}

    /// Processes `events` in arrival order, extending whatever `entries`/`callIndex`/`deltaIndex`
    /// state earlier `append` calls already built. Never rescans an entry already produced by an
    /// earlier call — the whole point of the incremental design.
    public mutating func append(_ events: [TaskEvent]) {
        for event in events {
            switch event.kind {
            case .taskStarted(let started):
                entries.append(.item(TimelineItem(id: event.seq, at: event.timestamp, body: .started(started))))
            case .assistantDelta(let delta):
                appendDelta(delta, seq: event.seq, at: event.timestamp)
            case .assistantText(let text, let messageID, let blockIndex):
                appendAssistantText(text, messageID: messageID, blockIndex: blockIndex, seq: event.seq, at: event.timestamp)
            case .toolCall(let call):
                if !call.callID.isEmpty { callIndex[call.callID] = entries.count }
                entries.append(.item(TimelineItem(id: event.seq, at: event.timestamp, body: .tool(call, nil))))
            case .toolResult(let result):
                guard let index = callIndex[result.callID], case .item(let item) = entries[index],
                      case .tool(let call, nil) = item.body else { continue }
                entries[index] = .item(TimelineItem(id: item.id, at: item.at, body: .tool(call, result)))
            case .userMessage(let text, let source, _):
                entries.append(.item(TimelineItem(id: event.seq, at: event.timestamp, body: .message(text: text, source: source))))
            case .notice(let text):
                entries.append(.item(TimelineItem(id: event.seq, at: event.timestamp, body: .notice(text))))
            case .undelivered(_, let text, let reason):
                entries.append(.item(TimelineItem(id: event.seq, at: event.timestamp, body: .undelivered(text: text, reason: reason))))
            case .taskFinished(let status, let exitCode, let summary, _):
                entries.append(.item(TimelineItem(id: event.seq, at: event.timestamp, body: .finished(status: status, exitCode: exitCode, summary: summary))))
            case .usage, .unknown:
                continue
            }
        }
    }

    private mutating func appendDelta(_ delta: TaskEvent.AssistantDelta, seq: Int, at timestamp: Date?) {
        guard let messageID = delta.messageID, let blockIndex = delta.blockIndex else {
            // No identity to merge on: its own standalone incomplete item, never merged.
            let buffer = ChunkBuffer()
            buffer.chunks.append(delta.text)
            entries.append(.streamingText(id: seq, timestamp: timestamp, buffer: buffer))
            return
        }
        let key = DeltaKey(messageID: messageID, blockIndex: blockIndex)
        if let index = deltaIndex[key], case .streamingText(let id, let existingTimestamp, var buffer) = entries[index] {
            // Codex review round 2, finding 1: `TimelineBuilder` is a value type, but `entries`
            // holding a class-typed `ChunkBuffer` lets that specific piece of state escape struct
            // copy semantics — copying a builder (e.g. handing one to another actor) would otherwise
            // leave both copies' `.streamingText` entries pointing at the SAME buffer, so mutating
            // one through `append` would silently mutate the other's `items` too.
            //
            // `entries[index] = .placeholder` first detaches THIS array's own strong reference to
            // `buffer`, so the uniqueness check below sees only what actually aliases it: our local
            // `buffer` variable, plus (only if this builder's `entries` storage is itself still
            // shared with another `TimelineBuilder` copy) that other copy's own still-intact
            // reference. Skipping this detach would make the check see 2 references — this array's
            // stored copy AND our local extraction — even with no other builder involved at all,
            // permanently defeating the fast path below.
            entries[index] = .placeholder
            if isKnownUniquelyReferenced(&buffer) {
                // Not shared with any other builder: append in place, O(chunk) amortized, exactly as
                // before this fix.
                buffer.chunks.append(delta.text)
            } else {
                // Shared — clone once so mutating OUR copy can never mutate theirs. A one-time
                // O(current chunk count) cost, paid at most once per divergence between copies, the
                // same shape Array's own copy-on-write already accepts elsewhere in this type.
                let clone = ChunkBuffer()
                clone.chunks = buffer.chunks
                clone.chunks.append(delta.text)
                buffer = clone
            }
            entries[index] = .streamingText(id: id, timestamp: existingTimestamp, buffer: buffer)
        } else {
            let buffer = ChunkBuffer()
            buffer.chunks.append(delta.text)
            deltaIndex[key] = entries.count
            entries.append(.streamingText(id: seq, timestamp: timestamp, buffer: buffer))
        }
    }

    private mutating func appendAssistantText(_ text: String, messageID: String?, blockIndex: Int?, seq: Int, at timestamp: Date?) {
        if let messageID, let blockIndex {
            let key = DeltaKey(messageID: messageID, blockIndex: blockIndex)
            if let index = deltaIndex[key], case .streamingText(let id, let existingAt, _) = entries[index] {
                entries[index] = .item(TimelineItem(id: id, at: existingAt, body: .text(text, streaming: false)))
                deltaIndex[key] = nil
                return
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.append(.item(TimelineItem(id: seq, at: timestamp, body: .text(text, streaming: false))))
    }

    /// The current materialized snapshot. Only an in-progress streamed block is joined here (once,
    /// at read time — Codex review round 1, finding 2) — every other entry is already a finished
    /// `TimelineItem` with nothing left to compute.
    public var items: [TimelineItem] {
        entries.map { entry in
            switch entry {
            case .item(let item): return item
            case .streamingText(let id, let timestamp, let buffer):
                return TimelineItem(id: id, at: timestamp, body: .text(buffer.chunks.joined(), streaming: true))
            case .placeholder:
                // Never observable: `appendDelta` is the only writer of `.placeholder`, and it always
                // overwrites the slot before returning, within the same synchronous call.
                preconditionFailure("TimelineBuilder.Entry.placeholder escaped its own function")
            }
        }
    }
}

public enum Timeline {
    /// One-shot conversion, kept for callers (piece 7's `ConversationTimeline`, tests, previews)
    /// that already have the whole event list in hand — a thin wrapper over `TimelineBuilder` so its
    /// behavior (pairing, accumulation, replacement) lives in exactly one place. A caller that
    /// receives events incrementally over time should hold its own `TimelineBuilder` and `append` to
    /// it directly instead of calling this repeatedly (see `EventStreamRepositoryImpl`).
    public static func items(from events: [TaskEvent]) -> [TimelineItem] {
        var builder = TimelineBuilder()
        builder.append(events)
        return builder.items
    }

    public static func activity(from events: [TaskEvent]) -> ActivityCounts {
        var counts = ActivityCounts()
        for event in events {
            guard case .toolCall(let call) = event.kind else { continue }
            counts.toolCalls += 1
            if call.category == "edit" || call.category == "write" { counts.edits += 1 }
            if call.category == "shell" { counts.commands += 1 }
        }
        return counts
    }

    /// The latest tool call still waiting for its result — the inspector's "Now".
    public static func current(in items: [TimelineItem]) -> TimelineItem? {
        items.last(where: \.isRunningTool)
    }

    public static func prompt(in events: [TaskEvent]) -> String? {
        for event in events {
            if case .taskStarted(let started) = event.kind { return started.prompt }
        }
        return nil
    }
}

extension TaskEvent.ToolCall {
    /// One line for a row: the command, else the path, else the input preview.
    public var headline: String {
        if let command, !command.isEmpty { return command }
        if let path, !path.isEmpty { return path }
        return inputPreview
    }
}

// MARK: - ConversationTimeline (Monitor piece 7)

/// One conversation member's own event log, for `ConversationTimeline.rows(members:)`.
public struct ConversationMember: Sendable {
    public let task: TaskInfo
    public let events: [TaskEvent]

    public init(task: TaskInfo, events: [TaskEvent]) {
        self.task = task
        self.events = events
    }
}

/// One conversation member's own ALREADY-BUILT timeline items, for
/// `ConversationTimeline.rows(itemMembers:)` — Codex review round 2, finding 2: lets a caller that
/// already holds a repository's own incrementally-maintained per-task `items` snapshot (e.g.
/// `EventStreamRepository.itemsPublisher(for:)`) build the conversation's rows without re-running
/// `Timeline.items(from:)` over the whole raw history on every publication. `prompt` stands in for
/// what `Timeline.prompt(in: events)` would have found (the first member's own prompt names the
/// conversation; a follow-up's own prompt labels its separator) — a caller building this from raw
/// events uses `Timeline.prompt(in:)` itself; one already holding a repository's own per-task state
/// uses its existing `prompt(for:)` accessor instead.
public struct ConversationItemMember: Sendable {
    public let task: TaskInfo
    public let items: [TimelineItem]
    public let prompt: String?

    public init(task: TaskInfo, items: [TimelineItem], prompt: String?) {
        self.task = task
        self.items = items
        self.prompt = prompt
    }
}

/// One row of a conversation's concatenated timeline: either a member's own paired `TimelineItem`
/// or a synthetic turn separator ahead of a follow-up.
public struct ConversationTimelineRow: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A follow-up's own prompt and time, shown as "You · HH:MM — <message>" ahead of its turn.
        case separator(text: String)
        case item(TimelineItem)
    }

    /// Globally unique across the whole concatenation — never just `TimelineItem.id` (an `Int`
    /// `seq`), which restarts at every member (Review round 1, item 1's task-scoped identity).
    public let id: String
    public let taskID: String
    public let timestamp: Date?
    public let kind: Kind
    /// Whether this row belongs to the conversation's own current, still-running turn — never true
    /// for an older (necessarily terminal) member's row, even while the newest turn runs (Review
    /// round 1, item 1: "an unfinished tool in an old turn shows 'no result', never a spinner").
    public let live: Bool

    public init(id: String, taskID: String, timestamp: Date?, kind: Kind, live: Bool) {
        self.id = id
        self.taskID = taskID
        self.timestamp = timestamp
        self.kind = kind
        self.live = live
    }
}

public enum ConversationTimeline {
    /// `members` ordered oldest to newest, each with its own raw events — a thin wrapper over
    /// `rows(itemMembers:)` (Codex review round 2, finding 2) for callers that only have raw events
    /// in hand (tests, previews, a genuine one-shot need): every member's own events are paired via
    /// `Timeline.items(from:)` first, then handed to the real implementation below. A caller that
    /// already holds a repository's own incrementally-maintained per-task `items` should call
    /// `rows(itemMembers:)` directly instead, to avoid rebuilding the whole timeline on every
    /// publication.
    public static func rows(members: [ConversationMember]) -> [ConversationTimelineRow] {
        rows(itemMembers: members.map {
            ConversationItemMember(task: $0.task, items: Timeline.items(from: $0.events), prompt: Timeline.prompt(in: $0.events))
        })
    }

    /// `itemMembers` ordered oldest to newest, each already carrying its own paired `items` (call ids
    /// and `seq` both restart per task, so pairing must stay scoped per member — Review round 1, item
    /// 1 — which is why this never re-pairs across members, only concatenates what each member's own
    /// `items` already settled). Concatenated in order with a turn separator ahead of every follow-up
    /// (every member after the first) carrying that member's own prompt and start time (Review round
    /// 1, item 6). A live-input `user_message(source: "initial")` that duplicates the separator's own
    /// text is dropped so it is not shown twice, as is a follow-up's own `task_started` row; any other
    /// message (e.g. one injected mid-run) still shows.
    public static func rows(itemMembers: [ConversationItemMember]) -> [ConversationTimelineRow] {
        var rows: [ConversationTimelineRow] = []
        for (index, member) in itemMembers.enumerated() {
            let isCurrentTurn = index == itemMembers.count - 1
            let live = isCurrentTurn && member.task.status.isRunning
            let prompt = member.prompt
            if index > 0 {
                rows.append(ConversationTimelineRow(
                    id: "sep:\(member.task.taskID)", taskID: member.task.taskID, timestamp: member.task.startedAt,
                    kind: .separator(text: prompt ?? ""), live: false
                ))
            }
            for item in member.items {
                if index > 0, case .message(let text, let source) = item.body, source == "initial", text == prompt {
                    continue
                }
                // A follow-up's own "started" row would repeat what its separator already says.
                if index > 0, case .started = item.body { continue }
                rows.append(ConversationTimelineRow(
                    id: "\(member.task.taskID)#\(item.id)", taskID: member.task.taskID, timestamp: item.at,
                    kind: .item(item), live: live
                ))
            }
        }
        return rows
    }
}
