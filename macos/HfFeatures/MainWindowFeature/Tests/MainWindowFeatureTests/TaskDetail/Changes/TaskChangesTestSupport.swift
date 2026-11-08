import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - ChangesJSON

/// Inline `task-changes.v1` documents, built as JSON values and decoded only through the public
/// `TaskChangesPage(raw:requestedLimit:)` and `TaskChangesListingBuilder`. Nothing is read from the vendored bundle:
/// each named fixture below restates the content of the file it cites.
enum ChangesJSON {
    static let observed = "2026-10-14T17:45:50+00:00"
    static let base = String(repeating: "a", count: 40)
    static let head = String(repeating: "b", count: 40)

    // MARK: Builders

    /// One row. A nil `additions` or `deletions` is a JSON null; `encoded` makes the path a `path_bytes_b64` row.
    static func row(
        _ path: String = "a.txt", encoded: Data? = nil, pathTruncated: Bool = false, status: String = "modified",
        additions: Int? = 1, deletions: Int? = 0, binary: Bool = false, content: String = "available", reason: String? = nil,
        bytes: Int = 10
    ) -> JSONValue {
        .object([
            "path": encoded == nil ? .string(path) : .null,
            "path_bytes_b64": encoded.map { .string($0.base64EncodedString()) } ?? .null,
            "path_truncated": .bool(pathTruncated), "old_path": .null, "status": .string(status),
            "additions": additions.map { .number(Double($0)) } ?? .null,
            "deletions": deletions.map { .number(Double($0)) } ?? .null,
            "binary": .bool(binary),
            "content": .object(["state": .string(content), "reason": reason.map(JSONValue.string) ?? .null, "bytes": .number(Double(bytes))])
        ])
    }

    /// `count` rows with distinct paths, for reveal and truncation cases.
    static func rows(_ count: Int, prefix: String = "file") -> [JSONValue] {
        (0 ..< count).map { row("\(prefix)-\($0).txt") }
    }

    /// A committed-range scope. `rowCount` defaults to the number of rows given.
    static func committed(
        state: String = "available", reason: String? = nil, rowCount: Int? = nil, rows: [JSONValue] = [], truncated: Bool = false
    ) -> JSONValue {
        .object([
            "state": .string(state), "reason": reason.map(JSONValue.string) ?? .null, "row_count": .number(Double(rowCount ?? rows.count)),
            "rows_truncated": .bool(truncated), "observed_at": .string(observed), "rows": .array(rows)
        ])
    }

    /// A working-tree scope, which also carries the conflict fields.
    static func working(
        state: String = "available", reason: String? = nil, rowCount: Int? = nil, rows: [JSONValue] = [], truncated: Bool = false,
        unmergedUnknown: Bool = false, conflicts: [String] = [], conflictsTruncated: Bool = false
    ) -> JSONValue {
        var scope = committed(state: state, reason: reason, rowCount: rowCount, rows: rows, truncated: truncated)
        guard case .object(var fields) = scope else { return scope }
        fields["counts_and_patch_separate"] = .bool(true)
        fields["unmerged_unknown"] = .bool(unmergedUnknown)
        fields["reported_conflicts"] = .object([
            "names": .array(conflicts.map { .object(["path": .string($0), "path_bytes_b64": .null]) }),
            "truncated": .bool(conflictsTruncated)
        ])
        scope = .object(fields)
        return scope
    }

    /// One repository. A nil scope is left out of the document.
    static func repository(
        root: String? = "/workspace/repo", state: String = "available", reason: String? = nil, fieldsTruncated: Bool = false,
        baselineDirty: JSONValue = .bool(false), committed: JSONValue? = ChangesJSON.committed(), working: JSONValue? = ChangesJSON.working()
    ) -> JSONValue {
        var scopes: [String: JSONValue] = [:]
        if let committed { scopes["committed_range"] = committed }
        if let working { scopes["working_tree"] = working }
        return .object([
            "repository_root": root.map(JSONValue.string) ?? .null, "worktree": root.map(JSONValue.string) ?? .null,
            "git_common_dir": root.map { $0.count < 4000 ? .string($0 + "/.git") : .null } ?? .null, "base_commit": .string(base),
            "base_provenance": .string("dispatch"), "head_commit": .string(head), "observed_at": .string(observed),
            "baseline_dirty": baselineDirty, "attribution": .string(TaskChangesRepositoryEntry.attribution),
            "fields_truncated": .bool(fieldsTruncated), "state": .string(state), "reason": reason.map(JSONValue.string) ?? .null,
            "scopes": .object(scopes)
        ])
    }

    /// One listing page.
    static func page(
        task: String = "t1", capture: (state: String, reason: String?) = ("available", nil), repositories: [JSONValue] = [],
        limit: Int = 200, cursor: String? = nil
    ) -> JSONValue {
        .object([
            "task_id": .string(task), "mode": .string("list"),
            "capture": .object(["state": .string(capture.state), "reason": capture.reason.map(JSONValue.string) ?? .null]),
            "repositories": .array(repositories), "limit": .number(Double(limit)), "has_more": .bool(cursor != nil),
            "next_cursor": cursor.map(JSONValue.string) ?? .null, "observed_at": .string("2026-10-14T17:46:40+00:00")
        ])
    }

    // MARK: Decoding

    /// The snapshot of pages decoded in order through the public page type and the listing builder.
    static func snapshot(_ pages: [(raw: JSONValue, limit: Int)]) throws -> TaskChangesSnapshot {
        var builder = TaskChangesListingBuilder()
        for entry in pages {
            let decoded = try #require(entry.raw.objectValue.flatMap { TaskChangesPage(raw: $0, requestedLimit: entry.limit) })
            try builder.append(decoded)
        }
        return try builder.finish()
    }

    /// A one-page snapshot at the default page limit.
    static func snapshot(_ raw: JSONValue, limit: Int = 200) throws -> TaskChangesSnapshot { try snapshot([(raw, limit)]) }

    /// The single page behind a snapshot, for the repository-name function that takes entries.
    static func entries(_ repositories: [JSONValue]) throws -> [TaskChangesRepositoryEntry] {
        let raw = page(repositories: repositories)
        return try #require(raw.objectValue.flatMap { TaskChangesPage(raw: $0, requestedLimit: 200) }).repositories
    }

    // MARK: Text chunks

    /// The selector of a row of `availableListing()`.
    static func selector(
        _ path: String = "README.md", scope: TaskChangesScopeName = .committedRange, root: String = "/workspace/repo"
    ) -> TaskChangesSelector {
        TaskChangesSelector(repositoryRoot: root, scope: scope, pathBytes: Data(path.utf8))!
    }

    /// One text-mode chunk of the row `selector` addresses. `bytes` is this chunk's payload, `total` the whole patch.
    static func chunk(
        _ selector: TaskChangesSelector, bytes: Data, offset: Int = 0, total: Int? = nil, cursor: String? = nil, state: String = "available",
        reason: String? = nil, status: String = "modified", task: String = "t1"
    ) -> JSONValue {
        let whole = total ?? offset + bytes.count
        let text = String(data: bytes, encoding: .utf8)
        let path = String(data: selector.pathBytes, encoding: .utf8)
        return .object([
            "task_id": .string(task), "mode": .string("text"), "capture": .object(["state": .string("available"), "reason": .null]),
            "repository_root": .string(selector.repositoryRoot), "scope": .string(selector.scope.rawValue),
            "path": path.map(JSONValue.string) ?? .null,
            "path_bytes_b64": path == nil ? .string(selector.pathBytes.base64EncodedString()) : .null,
            "path_truncated": .bool(false), "status": .string(status), "additions": .number(1), "deletions": .number(0), "binary": .bool(false),
            "content": .object(["state": .string(state), "reason": reason.map(JSONValue.string) ?? .null, "bytes": .number(Double(whole))]),
            "text": text.map(JSONValue.string) ?? .null, "text_b64": text == nil ? .string(bytes.base64EncodedString()) : .null,
            "offset": .number(Double(offset)), "returned_bytes": .number(Double(bytes.count)), "total_bytes": .number(Double(whole)),
            "has_more": .bool(offset + bytes.count < whole), "next_cursor": cursor.map(JSONValue.string) ?? .null,
            "observed_at": .string("2026-10-14T17:46:40+00:00")
        ])
    }

    /// The decoded chunk, through the public type.
    static func decodedChunk(_ raw: JSONValue) throws -> TaskChangesTextChunk {
        try #require(raw.objectValue.flatMap(TaskChangesTextChunk.init(raw:)))
    }

    /// The whole patch of `selector`, assembled from one chunk through the public assembler.
    static func patch(
        _ selector: TaskChangesSelector, bytes: Data, state: String = "available", reason: String? = nil, task: String = "t1"
    ) throws -> TaskChangesPatch {
        var assembler = TaskChangesTextAssembler(selector: selector)
        try assembler.append(decodedChunk(chunk(selector, bytes: bytes, state: state, reason: reason, task: task)))
        return try assembler.finish()
    }

    /// A small valid unified diff.
    static let sampleDiff = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1,2 @@\n x\n+y\n"

    // MARK: Named fixtures

    /// ctl-task-changes-available-listing.json (limit 2, more pages) and ctl-task-changes-listing-next-page.json (limit 200),
    /// read as one listing: committed rows README.md, docs/guide.md, src/app.py and assets/logo.png (binary); working-tree rows
    /// src/app.py and notes.txt (untracked, name only).
    static func availableListing(readmeBytes: Int = 42, readmeAdditions: Int = 1) throws -> TaskChangesSnapshot {
        let first = page(task: "task-changes-available", repositories: [repository(
            committed: committed(rowCount: 4, rows: [
                row("README.md", status: "added", additions: readmeAdditions, deletions: 0, bytes: readmeBytes),
                row("docs/guide.md", status: "added", additions: 1, deletions: 0, bytes: 1323)
            ]),
            working: working(rowCount: 2))], limit: 2, cursor: "cursor-page-2")
        let second = page(task: "task-changes-available", repositories: [repository(
            committed: committed(rowCount: 4, rows: [
                row("src/app.py", status: "modified", additions: 1, deletions: 0, bytes: 139),
                row("assets/logo.png", status: "added", additions: nil, deletions: nil, binary: true, content: "binary", bytes: 0)
            ]),
            working: working(rowCount: 2, rows: [
                row("src/app.py", status: "modified", additions: 1, deletions: 0, bytes: 139),
                row("notes.txt", status: "untracked", additions: nil, deletions: nil, content: "not_captured", reason: "untracked", bytes: 0)
            ]))], limit: 200)
        return try snapshot([(first, 2), (second, 200)])
    }

    /// ctl-task-changes-incomplete.json: capture incomplete (capture_timeout); committed scope incomplete with one truncated row;
    /// working tree available with zero rows.
    static func incomplete() throws -> TaskChangesSnapshot {
        try snapshot(page(task: "task-changes-incomplete", capture: ("incomplete", "capture_timeout"), repositories: [repository(
            state: "incomplete", reason: "capture_timeout",
            committed: committed(state: "incomplete", reason: "capture_timeout", rows: [
                row("big.txt", content: "truncated", reason: "capture_timeout", bytes: 40)
            ]),
            working: working())]))
    }

    /// A capture-only document: no repositories.
    static func captureOnly(task: String, state: String, reason: String?) throws -> TaskChangesSnapshot {
        try snapshot(page(task: task, capture: (state, reason)))
    }

    /// ctl-task-changes-no-repository.json
    static func noRepository() throws -> TaskChangesSnapshot { try captureOnly(task: "task-changes-none", state: "available", reason: "no_repository") }
    /// ctl-task-changes-not-captured-missing.json
    static func notCapturedMissing() throws -> TaskChangesSnapshot {
        try captureOnly(task: "task-changes-missing", state: "not_captured", reason: "capture_missing")
    }

    /// ctl-task-changes-not-captured-unobserved.json
    static func notCapturedUnobserved() throws -> TaskChangesSnapshot {
        try captureOnly(task: "task-changes-unobserved", state: "not_captured", reason: "outcome_unobserved")
    }

    /// ctl-task-changes-pending-running.json
    static func pendingRunning() throws -> TaskChangesSnapshot { try captureOnly(task: "task-changes-running", state: "pending", reason: "task_running") }
    /// ctl-task-changes-pending-settling.json
    static func pendingSettling() throws -> TaskChangesSnapshot {
        try captureOnly(task: "task-changes-settling", state: "pending", reason: "capture_settling")
    }

    /// ctl-task-changes-unavailable.json
    static func unavailable() throws -> TaskChangesSnapshot { try captureOnly(task: "task-changes-unavailable", state: "unavailable", reason: "capture_error") }
    /// ctl-task-changes-document-invalid.json
    static func documentInvalid() throws -> TaskChangesSnapshot {
        try captureOnly(task: "task-changes-invalid", state: "unavailable", reason: "changes_document_invalid")
    }

    /// A complete capture of one repository with no rows in either scope (the zero state).
    static func zeroRows() throws -> TaskChangesSnapshot {
        try snapshot(page(repositories: [repository()]))
    }

    /// ctl-task-changes-text-complete.json: the whole patch of src/app.py in committed_range in one chunk.
    static let textCompleteText = "diff --git a/src/app.py b/src/app.py\nindex 1111111..2222222 100644\n--- a/src/app.py\n+++ b/src/app.py\n"
        + "@@ -1 +1,2 @@\n print('a')\n+print('b')\n"

    /// ctl-task-changes-text-chunk.json and ctl-task-changes-text-chunk-next.json: the first two chunks of docs/guide.md (1323 bytes in all).
    static func guideChunks() throws -> (first: TaskChangesTextChunk, next: TaskChangesTextChunk, selector: TaskChangesSelector) {
        let address = selector("docs/guide.md")
        let line = "\n+one more line of documentation"
        let first = Data(("diff --git a/docs/guide.md b/docs/guide.md" + String(repeating: line, count: 9)).utf8)
        let second = Data(String(repeating: line, count: 8).utf8)
        let one = try decodedChunk(chunk(address, bytes: first, total: 1323, cursor: "cursor-text-2", status: "added", task: "task-changes-available"))
        let two = try decodedChunk(chunk(address, bytes: second, offset: first.count, total: 1323, cursor: "cursor-text-3", status: "added",
                                         task: "task-changes-available"))
        return (one, two, address)
    }

    // MARK: Named refusals

    /// ctl-task-changes-cursor-expired.json
    static let cursorExpired = ToolError.structuredRefusal(
        code: "changes_cursor_expired", message: "The stored changes changed or are no longer available", data: ["reload": .string("first")])
    /// ctl-task-changes-cursor-invalid.json
    static let cursorInvalid = ToolError.refused(code: "changes_cursor_invalid", message: "Malformed cursor")
    /// ctl-task-changes-direct-caller-refused.json
    static let directCallerRefused = ToolError.refused(code: "caller_undecidable", message: "Task history reads require a verified direct caller")
    /// ctl-task-changes-entry-not-found.json
    static let entryNotFound = ToolError.refused(code: "changes_entry_not_found", message: "No such repository, scope or path in the stored changes")
    /// ctl-task-changes-page-too-large.json
    static let pageTooLarge = ToolError.refused(code: "changes_page_too_large", message: "The smallest page of the stored changes exceeds the document bound")
    /// ctl-task-changes-pending-launch.json
    static let pendingLaunch = ToolError.structuredRefusal(
        code: "task_pending_launch", message: "task has not started", data: ["launch_state": .string("waiting_for_resources")])
    /// ctl-task-changes-unknown-task.json
    static let unknownTask = ToolError.structuredRefusal(
        code: "unknown_task", message: "unknown task_id", data: ["code": .string("unknown_task"), "reason": .string("no_prefix_match")])
}

// MARK: - Builder helpers

extension TaskChangesPresentationBuilder {
    /// Builds a snapshot presentation for the member task `t1`.
    static func built(_ snapshot: TaskChangesSnapshot, taskID: String = "t1") -> TaskChangesBuilt {
        build(taskID: taskID, outcome: .snapshot(snapshot))
    }
}

extension TaskChangesBuilt {
    /// The note of a note presentation.
    var note: TaskChangesNote? {
        if case .note(let note) = presentation { return note }
        return nil
    }

    /// The document of a listing presentation.
    var document: TaskChangesDocument? {
        if case .document(let document) = presentation { return document }
        return nil
    }
}

extension TaskChangesDiffModel {
    /// The drawn lines, with their `+`, `-` or space prefix.
    var drawnLines: [String] { text.attributed.string.components(separatedBy: "\n") }

    /// The kind code (`TaskChangesDiffText.kindCode`) of each drawn line.
    var drawnKinds: [Int] {
        let attributed = text.attributed
        var location = 0
        return drawnLines.map { line in
            defer { location += (line as NSString).length + 1 }
            guard attributed.length > 0 else { return -1 }
            return attributed.attribute(TaskChangesDiffText.kindKey, at: min(location, attributed.length - 1), effectiveRange: nil) as? Int ?? -1
        }
    }
}

extension UnifiedDiffLines.Kind {
    var code: Int { TaskChangesDiffText.kindCode(self) }
}
