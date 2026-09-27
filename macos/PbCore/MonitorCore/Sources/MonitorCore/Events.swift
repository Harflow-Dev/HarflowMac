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
        case assistantText(String)
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
            kind = .assistantText(s("text") ?? "")
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
        case text(String)
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

public enum Timeline {
    /// Merge each `tool_result` into its `tool_call` (by `call_id`), drop `usage` and unknown
    /// kinds. A result with no matching call is dropped too: there is nothing to attach it to.
    public static func items(from events: [TaskEvent]) -> [TimelineItem] {
        var items: [TimelineItem] = []
        var callIndex: [String: Int] = [:]
        for event in events {
            switch event.kind {
            case .taskStarted(let started):
                items.append(TimelineItem(id: event.seq, at: event.timestamp, body: .started(started)))
            case .assistantText(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                items.append(TimelineItem(id: event.seq, at: event.timestamp, body: .text(text)))
            case .toolCall(let call):
                if !call.callID.isEmpty { callIndex[call.callID] = items.count }
                items.append(TimelineItem(id: event.seq, at: event.timestamp, body: .tool(call, nil)))
            case .toolResult(let result):
                guard let index = callIndex[result.callID], case .tool(let call, nil) = items[index].body else { continue }
                items[index] = TimelineItem(id: items[index].id, at: items[index].at, body: .tool(call, result))
            case .userMessage(let text, let source, _):
                items.append(TimelineItem(id: event.seq, at: event.timestamp, body: .message(text: text, source: source)))
            case .notice(let text):
                items.append(TimelineItem(id: event.seq, at: event.timestamp, body: .notice(text)))
            case .undelivered(_, let text, let reason):
                items.append(TimelineItem(id: event.seq, at: event.timestamp, body: .undelivered(text: text, reason: reason)))
            case .taskFinished(let status, let exitCode, let summary, _):
                items.append(TimelineItem(id: event.seq, at: event.timestamp, body: .finished(status: status, exitCode: exitCode, summary: summary)))
            case .usage, .unknown:
                continue
            }
        }
        return items
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
    /// `members` ordered oldest to newest, each with its own raw events. Every member's own events
    /// are paired independently (`Timeline.items(from:)` is already scoped to one event stream —
    /// call ids and `seq` both restart per task), then concatenated in order with a turn separator
    /// ahead of every follow-up (every member after the first) carrying that member's own prompt and
    /// start time (Review round 1, item 6). A live-input `user_message(source: "initial")` that
    /// duplicates the separator's own text is dropped so it is not shown twice, as is a follow-up's own
    /// `task_started` row; any other message
    /// (e.g. one injected mid-run) still shows.
    public static func rows(members: [ConversationMember]) -> [ConversationTimelineRow] {
        var rows: [ConversationTimelineRow] = []
        for (index, member) in members.enumerated() {
            let isCurrentTurn = index == members.count - 1
            let live = isCurrentTurn && member.task.status.isRunning
            let prompt = Timeline.prompt(in: member.events)
            if index > 0 {
                rows.append(ConversationTimelineRow(
                    id: "sep:\(member.task.taskID)", taskID: member.task.taskID, timestamp: member.task.startedAt,
                    kind: .separator(text: prompt ?? ""), live: false
                ))
            }
            for item in Timeline.items(from: member.events) {
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
