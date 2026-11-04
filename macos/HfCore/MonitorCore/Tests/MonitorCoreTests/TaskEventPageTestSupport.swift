import Foundation
@testable import MonitorCore
import Testing

// MARK: - Task event page test support

func taskEventPageFixture(_ name: String) throws -> [String: JSONValue] {
    let url = try #require(Bundle.module.url(forResource: "ctl-task-events-\(name)", withExtension: "json", subdirectory: "ContractsV1"))
    return try #require(JSONValue.parse(Data(contentsOf: url))?.objectValue)
}

func eventPageRaw(events: [[String: JSONValue]] = [eventRecordRaw()]) -> [String: JSONValue] {
    let span: JSONValue = if let first = events.first?["seq"], let last = events.last?["seq"] {
        .object(["first_seq": first, "last_seq": last])
    } else {
        .null
    }
    return ["task_id": .string("task"), "order": .string("ascending"), "kinds": .string("all"),
     "events": .array(events.map(JSONValue.object)), "older_cursor": .null, "newer_cursor": .string("opaque/newer"),
     "has_older": .bool(false), "has_newer": .bool(false),
     "span": span,
     "skipped": .object(["malformed": .number(0), "oversized": .number(0)]), "gaps": .array([]),
     "log": .object(["state": .string("open"), "task_status": .string("running"), "output_drained": .bool(false),
                     "capture_state": .string("live"), "final_seq": .null]),
     "change_token": .string("opaque-token"), "observed_at": .string("2026-10-14T17:46:40+00:00")]
}

func eventRecordRaw() -> [String: JSONValue] {
    ["product": .string("harflow"), "format": .string("harflow.event"), "v": .number(1),
     "product_version": .string("0.0.6"), "seq": .number(7), "kind": .string("assistant_text"),
     "observed_at": .null, "text": .string("hello")]
}

func eventSelection(_ raw: [String: JSONValue]) -> TaskEventKindSelection {
    if let kinds = raw["kinds"]?.arrayValue { return .kinds(kinds.compactMap(\.stringValue)) }
    return raw["kinds"]?.stringValue == "default" ? .default : .all
}

func eventOutput(_ raw: [String: JSONValue]) -> ProcessOutput {
    ProcessOutput(exitCode: 0, stdout: ctlJSON(JSONValue.object(["result": .object(raw)]).rendered()), stderr: "")
}

func eventProbe(_ environment: [String: String], capability: Bool = true, mode: String = "valid") -> ProcessOutput {
    let root = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
    let raw: [String: JSONValue] = [
        "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
        "product_version": .string(HarflowVersion.current), "component": .string("engine"),
        "state_root": .string(mode == "foreign-root" ? "/foreign" : root),
        "contracts": .object([
            "ctl": .object(["format": .string("harflow.ctl"), "v": .number(mode == "ctl" ? 99 : 1)]),
            "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
            "events": .object(["format": .string("harflow.event"), "v": .number(mode == "events" ? 99 : 1)])
        ]),
        "capabilities": .array((["ctl.v1", "events.v1"] + (capability ? ["task-event-page.v1"] : [])).map(JSONValue.string)),
        "os": .string("darwin"), "architecture": .string("arm64")
    ]
    return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
}

final class EventReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func next() -> Int { lock.withLock { count += 1; return count } }
}
