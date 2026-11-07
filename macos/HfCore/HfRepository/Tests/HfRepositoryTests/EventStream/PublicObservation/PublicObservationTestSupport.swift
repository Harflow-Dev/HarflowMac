import Combine
import Foundation
@testable import HfRepository
import MonitorCore
import os

// MARK: - ObservationFixtures

enum ObservationFixtures {
    static func record(_ seq: Int, _ kind: String = "notice", _ payload: [String: JSONValue] = ["text": .string("message")]) -> [String: JSONValue] {
        var raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.event"),
            "v": .number(Double(1)), "product_version": .string("0.0.8"), "seq": .number(Double(seq)), "kind": .string(kind), "observed_at": .null]
        raw.merge(payload) { _, new in new }
        return raw
    }

    static func call(_ seq: Int, id: String, path: String) -> [String: JSONValue] {
        record(seq, "tool_call", ["call_id": .string(id), "tool": .string("edit"), "category": .string("edit"),
            "input_preview": .string("edit file"), "path": .string(path)])
    }

    static func result(_ seq: Int, id: String, ok: Bool) -> [String: JSONValue] {
        record(seq, "tool_result", ["call_id": .string(id), "output_tail": .string("done"), "ok": .bool(ok)])
    }

    static func page(_ events: [[String: JSONValue]] = [], older: String? = nil, newer: String = "live",
                     more: Bool = false, final: Int? = nil, capture: String = "live", malformed: Int = 0,
                     state: TaskEventLog.State? = nil) -> TaskEventPage {
        let seqs = events.compactMap { $0["seq"]?.wireIntegerValue }
        let span: JSONValue = seqs.first.map { .object(["first_seq": .number(Double($0)), "last_seq": .number(Double(seqs.last ?? $0))]) } ?? .null
        let raw: [String: JSONValue] = ["task_id": .string("task"), "order": .string("ascending"), "kinds": .string("all"),
            "events": .array(events.map(JSONValue.object)), "older_cursor": older.map(JSONValue.string) ?? .null,
            "newer_cursor": state == .unavailable ? .null : .string(newer), "has_older": .bool(older != nil), "has_newer": .bool(more), "span": span,
            "skipped": .object(["malformed": .number(Double(malformed)), "oversized": .number(Double(0))]), "gaps": .array([]),
            "log": .object(log(state: state, final: final, capture: capture)),
            "change_token": .string("change"), "observed_at": .string("2026-11-05T00:00:00Z")]
        guard let page = TaskEventPage(raw: raw, limit: 200) else { preconditionFailure("Invalid observation test page") }
        return page
    }

    /// The `log` object. Without `state` it keeps the legacy open/final derivation. With `state` it follows the
    /// vendored contract fixtures: only `open` is running and live; every other state is a finished task with
    /// `observed_terminal` capture, drained except `incomplete` and `unknown`, and `final` alone carries `final_seq`.
    private static func log(state: TaskEventLog.State?, final: Int?, capture: String) -> [String: JSONValue] {
        guard let state else {
            return ["state": .string(final == nil ? "open" : "final"), "task_status": .string(final == nil ? "running" : "completed"),
                    "capture_state": .string(capture), "output_drained": .bool(final != nil), "final_seq": final.map { .number(Double($0)) } ?? .null]
        }
        let open = state == .open
        let drained = ![.open, .incomplete, .unknown].contains(state)
        return ["state": .string(state.rawValue), "task_status": .string(open ? "running" : "completed"),
                "capture_state": .string(open ? capture : "observed_terminal"), "output_drained": .bool(drained),
                "final_seq": state == .final ? .number(Double(final ?? 1)) : .null]
    }
}

// MARK: - ObservationScriptReader

final class ObservationScriptReader: PublicEventObservationReader, Sendable {
    struct Request: Sendable {
        let taskID: String
        let position: TaskEventPagePosition
        let isCurrent: @Sendable () -> Bool
        let continuation: CheckedContinuation<Result<TaskEventPage, ToolError>, Never>
    }

    private let state = OSAllocatedUnfairLock(initialState: [Request]())
    var requests: [Request] { state.withLock { $0 } }
    func read(taskID: String, position: TaskEventPagePosition,
              operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskEventPage, ToolError> {
        await withCheckedContinuation { continuation in
            state.withLock { $0.append(Request(taskID: taskID, position: position, isCurrent: operationIsCurrent, continuation: continuation)) }
        }
    }

    func finish(_ index: Int, _ result: Result<TaskEventPage, ToolError>) { requests[index].continuation.resume(returning: result) }
}

// MARK: - ObservationMailbox

final class ObservationMailbox: Sendable {
    private struct State: Sendable {
        var pending: [@Sendable () -> Void] = []
        var values: [PublicEventObservationSnapshot] = []
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    var pendingCount: Int { state.withLock { $0.pending.count } }
    var values: [PublicEventObservationSnapshot] { state.withLock { $0.values } }
    func enqueue(_ callback: @escaping @Sendable () -> Void) { state.withLock { $0.pending.append(callback) } }
    func publish(_ snapshot: PublicEventObservationSnapshot) { state.withLock { $0.values.append(snapshot) } }
    func flush() {
        let callbacks = state.withLock { value in let callbacks = value.pending; value.pending.removeAll(); return callbacks }
        callbacks.forEach { $0() }
    }
}
