import Foundation

// MARK: - TaskSupervision

/// Engine evidence kept separate from task outcome and process ownership inference.
public struct TaskSupervision: Equatable, Sendable {
    /// A process identity requires both PID and start identity, so PID reuse is distinct.
    public struct ProcessIdentity: Equatable, Hashable, Sendable {
        public let pid: Int
        public let startTime: String

        init?(_ value: JSONValue?) {
            guard let object = value?.objectValue, let pid = object["pid"]?.wireIntegerValue, pid > 0,
                  let start = object["start_time"]?.stringValue, !start.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  start.utf8.count <= 128 else { return nil }
            self.pid = pid
            startTime = start
        }
    }

    /// Qualified engine observation; malformed optional evidence is ignored independently.
    public struct RestartObservation: Equatable, Hashable, Sendable {
        public let observedProcessStartedAt: String?
        public let previousServer: ProcessIdentity
        public let observerKind: String
        public let observingProcess: ProcessIdentity

        init?(_ value: JSONValue?) {
            guard let object = value?.objectValue,
                  let previous = ProcessIdentity(object["previous_server"]) else { return nil }
            if let kindValue = object["observer_kind"], kindValue != .null, kindValue.stringValue == nil { return nil }
            let kind = object["observer_kind"]?.stringValue ?? "server"
            guard kind == "server" || kind == "parent_process",
                  let current = ProcessIdentity(object[kind == "parent_process" ? "observing_process" : "current_server"]),
                  current != previous else { return nil }
            previousServer = previous
            observerKind = kind
            observingProcess = current
            observedProcessStartedAt = object["at"]?.stringValue
        }
    }

    public let restartObservation: RestartObservation?
    public let ownerState: String?
    public let processState: String?
    public let captureState: String?
    public let liveInputState: String?
    public let lastCapturedOutputAt: String?
    public let lastCapturedOutputSource: String?

    public init?(_ value: JSONValue) {
        guard let object = value.objectValue else { return nil }
        restartObservation = RestartObservation(object["adopted_after_restart"])
        ownerState = object["owner_state"]?.stringValue
        processState = object["process_state"]?.stringValue
        captureState = object["capture_state"]?.stringValue
        liveInputState = object["live_input_state"]?.stringValue
        lastCapturedOutputAt = object["last_captured_output_at"]?.stringValue
        lastCapturedOutputSource = object["last_captured_output_source"]?.stringValue
    }

    /// Positive evidence required for the quiet running claim.
    public var hasHealthyContinuity: Bool {
        restartObservation != nil && ownerState == "alive" && ["alive", "undecidable"].contains(processState ?? "") && captureState == "live"
            && ["open", "closed", "not_applicable"].contains(liveInputState ?? "")
    }

    public var notices: [String] { notices(isRunning: true) }

    /// Ownership uncertainty matters while execution is live; observed terminal owners are normally absent.
    public func notices(isRunning: Bool) -> [String] {
        var result: [String] = []
        if isRunning && ["unknown", "uncertain", "undecidable", "dead"].contains(ownerState ?? "") {
            result.append("Task connection is uncertain.")
        }
        if captureState == "lost_with_owner" || captureState == "lost" {
            result.append("Output capture stopped; capture was lost with its owner. No further captured summary is promised.")
        } else if captureState == "unknown" {
            result.append("Output capture ownership is unknown.")
        }
        if liveInputState == "closed_with_owner" || liveInputState == "lost" {
            result.append("Messages can no longer be delivered through the live input channel.")
        } else if liveInputState == "unknown" {
            result.append("Live input ownership is unknown.")
        }
        return result
    }

}

// MARK: - RecoveryActivityPage

/// Bounded backend-transcript activity. Its cursor and source IDs never identify task-log records.
public struct RecoveryActivityPage: Equatable, Sendable {
    public struct Event: Equatable, Sendable {
        public let sourceID: String
        public let timestamp: Date?
        public let kind: TaskEvent.Kind
        public let raw: JSONValue
    }

    public let events: [Event]
    public let nextCursor: String?
    public let reset: Bool
    public let notices: [String]

    public init?(_ value: JSONValue) {
        guard let page = value.objectValue,
              page["source"]?.stringValue == "backend_transcript",
              page["display_only"]?.boolValue == true,
              let values = page["events"]?.arrayValue, values.count <= 200,
              let reset = page["reset"]?.boolValue,
              let notices = page["notices"]?.arrayValue, notices.count <= 32,
              notices.allSatisfy({ ($0.stringValue?.utf8.count ?? Int.max) <= 4096 }),
              page["has_more"]?.boolValue == false else { return nil }
        var events: [Event] = []
        for value in values {
            guard let object = value.objectValue,
                  let kindName = object["kind"]?.stringValue,
                  let id = object["source_id"]?.stringValue, id.count == 64,
                  id.allSatisfy({ $0.isHexDigit }), value.rendered().utf8.count <= 65536 else { return nil }
            let kind: TaskEvent.Kind
            switch kindName {
            case "assistant_text":
                guard let text = object["text"]?.stringValue else { return nil }
                kind = .assistantText(text: text, messageID: nil, blockIndex: nil)
            case "tool_call":
                guard let callID = object["call_id"]?.stringValue ?? object["tool_use_id"]?.stringValue,
                      let tool = object["tool"]?.stringValue ?? object["name"]?.stringValue else { return nil }
                kind = .toolCall(TaskEvent.ToolCall(
                    callID: callID.hasPrefix("recovery:") ? callID : "recovery:\(callID)", tool: tool, category: object["category"]?.stringValue ?? "other",
                    inputPreview: object["input_preview"]?.stringValue ?? object["input"]?.rendered() ?? "",
                    path: object["path"]?.stringValue, command: object["command"]?.stringValue,
                    editOld: object["edit"]?["old"]?.stringValue, editNew: object["edit"]?["new"]?.stringValue
                ))
            case "tool_result":
                guard let callID = object["call_id"]?.stringValue ?? object["tool_use_id"]?.stringValue else { return nil }
                kind = .toolResult(TaskEvent.ToolResult(
                    callID: callID.hasPrefix("recovery:") ? callID : "recovery:\(callID)",
                    ok: object["ok"]?.boolValue ?? !(object["is_error"]?.boolValue ?? false),
                    outputTail: object["output_tail"]?.stringValue ?? object["text"]?.stringValue ?? "",
                    exitCode: object["exit_code"]?.intValue
                ))
            default: continue
            }
            events.append(Event(sourceID: id, timestamp: object["source_ts"]?.stringValue.flatMap(ISODate.parse), kind: kind, raw: value))
        }
        if let cursor = page["next_cursor"], cursor != .null,
           cursor.stringValue == nil || (cursor.stringValue?.utf8.count ?? 0) > 4096 { return nil }
        self.events = events
        nextCursor = page["next_cursor"]?.stringValue
        self.reset = reset
        self.notices = notices.compactMap(\.stringValue)
    }
}

public extension CtlClient {
    /// Reads an independent display-only recovery page after the standard runtime compatibility gate.
    func recoveryActivity(_ taskID: String, cursor: String? = nil) async -> Result<RecoveryActivityPage, ToolError> {
        var options = ["--limit=100"]
        if let cursor { options.append("--cursor=\(cursor)") }
        return await raw("recovery-activity", options: options, positionals: [taskID]).flatMap { output in
            guard let document = CtlDocument.firstJSONObject(in: output.stdout) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode, stderr: output.stderr))
            }
            if let error = document["error"]?.objectValue {
                let code = error["code"]?.stringValue ?? "error"
                let message = error["message"]?.stringValue ?? ""
                if code == "usage" { return .failure(.unsupportedCommand(tool: "harflow-ctl", command: "recovery-activity", detail: message)) }
                return .failure(.refused(code: code, message: message))
            }
            guard output.exitCode == 0 else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode, stderr: output.stderr))
            }
            guard document["task_id"]?.stringValue == taskID,
                  let value = document["recovery_activity"], let page = RecoveryActivityPage(value) else {
                return .failure(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode, stderr: "Malformed recovery activity page"))
            }
            return .success(page)
        }
    }
}
