import Foundation

/// Whether the agent's own edit tools report a path as having landed, failed, or never confirmed.
public enum EditedFileStatus: Equatable, Sendable {
    /// Its latest `tool_call`'s `tool_result` arrived with `ok == true`.
    case edited
    /// Its latest `tool_call`'s `tool_result` arrived with `ok == false`.
    case failed
    /// Its latest `tool_call` has no `tool_result` yet — or never got one (some backends never
    /// emit one for this call shape; see `README.md`'s edit-evidence table).
    case unconfirmed
}

/// One path the agent's own edit/write tools touched, for the Summary tab's "Files the agent
/// edited" section (decision 4, piece 2/3 of the Monitor architecture plan). Never git: this is
/// what the agent's own tools reported, which is why a shell command that edits a file is
/// invisible here (F-summary-3: the header note says so).
public struct EditedFile: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: EditedFileStatus

    public init(path: String, status: EditedFileStatus) {
        self.path = path
        self.status = status
    }
}

/// Builds `[EditedFile]` from a task's raw event stream — a `tool_call` (category `edit`/`write`,
/// non-empty `path`) paired with its `tool_result` by `call_id`.
public enum EditedFiles {
    /// Distinct paths, in first-seen order; a path's status is always its LATEST `tool_call`'s
    /// outcome, even when the result for an earlier call on the same path is still what most
    /// recently arrived. `read`/`shell`/`mcp`/`other` calls and a call with no (or empty) `path`
    /// are ignored outright — a shell command can edit a file, but this method has no way to know
    /// that, and would rather say nothing than guess.
    ///
    /// `repoPath`, when non-empty, is stripped as a prefix so a path under the repo renders
    /// relative to it; anything else (already relative, or outside the repo entirely) is shown
    /// exactly as the agent's tool reported it.
    public static func build(from events: [TaskEvent], repoPath: String) -> [EditedFile] {
        // Keyed by the *displayed* (repo-relative) path, so `/repo/a.swift` and `a.swift` are one
        // file whose latest call wins, never two rows with the same identity.
        var order: [String] = []
        var latest: [String: (callID: String, status: EditedFileStatus)] = [:]
        // A result counts only for the call it answers, and only while that call is still its
        // path's latest: processed in stream order, so a reused call id, a result for a superseded
        // call, or a result arriving before any call can never mark a pending edit as settled.
        var pendingPathByCallID: [String: String] = [:]

        for event in events {
            switch event.kind {
            case .toolCall(let call):
                guard call.category == "edit" || call.category == "write" else { continue }
                guard let rawPath = call.path, !rawPath.isEmpty else { continue }
                let path = relativized(rawPath, repoPath: repoPath)
                if latest[path] == nil { order.append(path) }
                latest[path] = (call.callID, .unconfirmed)
                pendingPathByCallID[call.callID] = path
            case .toolResult(let result):
                guard let path = pendingPathByCallID.removeValue(forKey: result.callID),
                      latest[path]?.callID == result.callID else { continue }
                latest[path] = (result.callID, result.ok ? .edited : .failed)
            default:
                continue
            }
        }

        return order.map { EditedFile(path: $0, status: latest[$0]?.status ?? .unconfirmed) }
    }

    private static func relativized(_ path: String, repoPath: String) -> String {
        guard !repoPath.isEmpty else { return path }
        let prefix = repoPath.hasSuffix("/") ? repoPath : repoPath + "/"
        guard path.hasPrefix(prefix) else { return path }
        return String(path.dropFirst(prefix.count))
    }
}
