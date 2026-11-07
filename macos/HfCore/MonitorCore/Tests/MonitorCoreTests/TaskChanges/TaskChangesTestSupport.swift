import Foundation
@testable import MonitorCore
import Testing

// MARK: - Fixture access

/// Reads the vendored `ctl-task-changes-*` fixtures. They are engine-recorded documents of the
/// contract owner; the manifest carries no `exit_code` or provenance for them, so exit codes are
/// stated by the tests themselves.
enum TCFixture {
    static let prefix = "ctl-task-changes-"

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ContractsV1"))
        return try Data(contentsOf: url)
    }

    static func file(_ stem: String) -> String { prefix + stem + ".json" }

    static func manifest() throws -> [String: JSONValue] {
        try #require(JSONValue.parse(data("manifest.json"))?.objectValue)
    }

    static func manifestCase(_ stem: String) throws -> [String: JSONValue] {
        try #require(manifest()["cases"]?.objectValue?[file(stem)]?.objectValue)
    }

    static func document(_ stem: String) throws -> [String: JSONValue] {
        try #require(JSONValue.parse(data(file(stem)))?.objectValue)
    }

    static func result(_ stem: String) throws -> [String: JSONValue] {
        try #require(document(stem)["result"]?.objectValue)
    }

    static func errorObject(_ stem: String) throws -> [String: JSONValue] {
        try #require(document(stem)["error"]?.objectValue)
    }

    static func manifestNames() throws -> Set<String> {
        Set(try #require(manifest()["cases"]?.objectValue).keys.filter { $0.hasPrefix(prefix) })
    }

    static func bundledNames() -> Set<String> {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "ContractsV1") ?? []
        return Set(urls.map(\.lastPathComponent).filter { $0.hasPrefix(prefix) })
    }

    /// The fixture exactly as the engine printed it, with the stated exit code.
    static func output(_ stem: String, exit: Int32) -> ProcessOutput {
        ProcessOutput(exitCode: exit, stdout: (try? data(file(stem))) ?? Data(), stderr: "")
    }

    static func page(_ stem: String, limit: Int = 200) throws -> TaskChangesPage {
        try #require(TaskChangesPage(raw: result(stem), requestedLimit: limit))
    }
}

// MARK: - JSON editing

/// One step of a path into a JSON tree.
enum TCStep: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)

    init(stringLiteral value: String) { self = .key(value) }
    init(integerLiteral value: Int) { self = .index(value) }
}

extension JSONValue {
    /// A copy with the value at `path` replaced, or removed when `value` is `nil`.
    func setting(_ path: [TCStep], to value: JSONValue?) -> JSONValue {
        setting(path[...], to: value)
    }

    private func setting(_ path: ArraySlice<TCStep>, to value: JSONValue?) -> JSONValue {
        guard let head = path.first else { return value ?? .null }
        let rest = path.dropFirst()
        switch (head, self) {
        case (.key(let key), .object(var object)):
            if rest.isEmpty {
                object[key] = value
            } else {
                object[key] = (object[key] ?? .null).setting(rest, to: value)
            }
            return .object(object)
        case (.index(let index), .array(var array)):
            if rest.isEmpty {
                if let value { array[index] = value } else { array.remove(at: index) }
            } else {
                array[index] = array[index].setting(rest, to: value)
            }
            return .array(array)
        default:
            return self
        }
    }

    var asObject: [String: JSONValue] { objectValue ?? [:] }
}

// MARK: - Synthetic documents

/// Builders of synthetic `task-changes.v1` documents. Not engine output.
enum Doc {
    static let taskID = "task-changes-synthetic"
    static let root = "/workspace/repo"
    static let stamp = "2026-10-14T17:45:50+00:00"

    static func string(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    static func count(_ value: Int?) -> JSONValue { value.map { .number(Double($0)) } ?? .null }

    static func content(state: String = "available", reason: String? = nil, bytes: Int = 10) -> JSONValue {
        .object(["state": .string(state), "reason": string(reason), "bytes": count(bytes)])
    }

    static func row(path: String? = "a.txt", pathB64: String? = nil, status: String = "modified", additions: Int? = 1, deletions: Int? = 0,
                    binary: Bool = false, pathTruncated: Bool = false, content: JSONValue? = nil) -> JSONValue {
        .object(["path": string(path), "path_bytes_b64": string(pathB64), "path_truncated": .bool(pathTruncated),
                 "old_path": .null, "status": .string(status), "additions": count(additions), "deletions": count(deletions),
                 "binary": .bool(binary), "content": content ?? self.content()])
    }

    static func committed(rows: [JSONValue] = [], rowCount: Int? = nil, state: String = "available", reason: String? = nil,
                          truncated: Bool = false) -> JSONValue {
        .object(["state": .string(state), "reason": string(reason), "row_count": count(rowCount ?? rows.count),
                 "rows_truncated": .bool(truncated), "observed_at": .string(stamp), "rows": .array(rows)])
    }

    static func working(rows: [JSONValue] = [], rowCount: Int? = nil, state: String = "available", reason: String? = nil,
                        truncated: Bool = false, unmergedUnknown: Bool = false, conflicts: [JSONValue] = []) -> JSONValue {
        var scope = committed(rows: rows, rowCount: rowCount, state: state, reason: reason, truncated: truncated).asObject
        scope["counts_and_patch_separate"] = .bool(true)
        scope["unmerged_unknown"] = .bool(unmergedUnknown)
        scope["reported_conflicts"] = .object(["names": .array(conflicts), "truncated": .bool(false)])
        return .object(scope)
    }

    static func repository(root: String? = Doc.root, state: String = "available", reason: String? = nil, dirty: JSONValue = .bool(false),
                           fieldsTruncated: Bool = false, scopes: [String: JSONValue]? = nil) -> JSONValue {
        .object(["repository_root": string(root), "worktree": string(root), "git_common_dir": string(root.map { $0 + "/.git" }),
                 "base_commit": .string(String(repeating: "a", count: 40)), "base_provenance": .string("dispatch"),
                 "head_commit": .string(String(repeating: "b", count: 40)), "observed_at": .string(stamp), "baseline_dirty": dirty,
                 "attribution": .string(TaskChangesRepositoryEntry.attribution), "fields_truncated": .bool(fieldsTruncated),
                 "state": .string(state), "reason": string(reason),
                 "scopes": .object(scopes ?? ["committed_range": committed(), "working_tree": working()])])
    }

    static func page(task: String = Doc.taskID, captureState: String = "available", captureReason: String? = nil,
                     repositories: [JSONValue]? = nil, limit: Int = 200, cursor: String? = nil) -> JSONValue {
        .object(["task_id": .string(task), "mode": .string("list"),
                 "capture": .object(["state": .string(captureState), "reason": string(captureReason)]),
                 "repositories": .array(repositories ?? [repository()]), "limit": count(limit), "has_more": .bool(cursor != nil),
                 "next_cursor": string(cursor), "observed_at": .string("2026-10-14T17:46:40+00:00")])
    }

    static func chunk(task: String = Doc.taskID, text: String? = "diff", textB64: String? = nil, offset: Int = 0, total: Int? = nil,
                      returned: Int? = nil, cursor: String? = nil, path: String? = "a.txt", pathB64: String? = nil,
                      scope: String = "working_tree", root: String? = Doc.root, pathTruncated: Bool = false,
                      status: String = "modified", content: JSONValue? = nil) -> JSONValue {
        let carried = text.map { Data($0.utf8).count } ?? textB64.flatMap { Data(base64Encoded: $0)?.count } ?? 0
        return .object([
            "task_id": .string(task), "mode": .string("text"), "capture": .object(["state": .string("available"), "reason": .null]),
            "repository_root": string(root), "scope": .string(scope), "path": string(path), "path_bytes_b64": string(pathB64),
            "path_truncated": .bool(pathTruncated), "status": .string(status), "additions": count(1), "deletions": count(0),
            "binary": .bool(false), "content": content ?? self.content(bytes: total ?? offset + carried), "text": string(text),
            "text_b64": string(textB64), "offset": count(offset), "returned_bytes": count(returned ?? carried),
            "total_bytes": count(total ?? offset + carried), "has_more": .bool(cursor != nil), "next_cursor": string(cursor),
            "observed_at": .string("2026-10-14T17:46:40+00:00")
        ])
    }

    static func decode(_ page: JSONValue, limit: Int = 200) -> TaskChangesPage? {
        TaskChangesPage(raw: page.asObject, requestedLimit: limit)
    }

    static func decodeChunk(_ chunk: JSONValue) -> TaskChangesTextChunk? {
        TaskChangesTextChunk(raw: chunk.asObject)
    }

    /// One page through a fresh builder to a snapshot.
    static func snapshot(_ page: JSONValue, limit: Int = 200) throws -> TaskChangesSnapshot {
        var builder = TaskChangesListingBuilder()
        try builder.append(try #require(decode(page, limit: limit)))
        return try builder.finish()
    }

    static func selector(root: String = Doc.root, scope: TaskChangesScopeName = .workingTree, path: String = "a.txt") throws -> TaskChangesSelector {
        try #require(TaskChangesSelector(repositoryRoot: root, scope: scope, pathBytes: Data(path.utf8)))
    }
}

// MARK: - Process doubles

/// Builds a `harflow-ctl` version-info answer. Not engine output: a synthetic stand-in.
func changesProbe(_ environment: [String: String], capability: Bool = true) -> ProcessOutput {
    let root = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
    let capabilities = ["ctl.v1", "setup.v1", "events.v1"] + (capability ? [CtlCapability.taskChanges] : [])
    let raw: [String: JSONValue] = [
        "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
        "product_version": .string(HarflowVersion.current), "component": .string("engine"), "state_root": .string(root),
        "contracts": .object([
            "ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
            "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
            "events": .object(["format": .string("harflow.event"), "v": .number(1)])
        ]),
        "capabilities": .array(capabilities.map(JSONValue.string)), "os": .string("darwin"), "architecture": .string("arm64")
    ]
    return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
}

/// A synthetic ctl result document with the current envelope.
func changesResult(_ result: JSONValue, exit: Int32 = 0) -> ProcessOutput {
    ProcessOutput(exitCode: exit, stdout: ctlJSON(JSONValue.object(["result": result]).rendered()), stderr: "")
}

func changesRefusal(code: String, data: JSONValue? = nil, exit: Int32 = 1) -> ProcessOutput {
    var error: [String: JSONValue] = ["code": .string(code), "message": .string(code)]
    if let data { error["data"] = data }
    return ProcessOutput(exitCode: exit, stdout: ctlJSON(JSONValue.object(["error": .object(error)]).rendered()), stderr: "")
}

/// Answers the version probe, then every other call from `answer`.
func changesRunner(capability: @escaping @Sendable () -> Bool = { true },
                   answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput) -> RecordingRunner {
    RecordingRunner { call in
        call.arguments == ["version-info", "--json"] ? changesProbe(call.environment, capability: capability()) : answer(call)
    }
}

func changesClient(_ runner: RecordingRunner) -> CtlClient {
    CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
}

/// Collects values from `@Sendable` closures.
final class TCBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { self.stored = value }

    var value: Value { lock.withLock { stored } }

    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

/// Scripted answers consumed in order; the last repeats.
final class TCScript: @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let outputs: [ProcessOutput]

    init(_ outputs: [ProcessOutput]) { self.outputs = outputs }

    func next() -> ProcessOutput {
        lock.withLock {
            let output = outputs[min(index, outputs.count - 1)]
            index += 1
            return output
        }
    }
}
