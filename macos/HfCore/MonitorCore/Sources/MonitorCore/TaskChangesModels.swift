import Foundation

// MARK: - TaskChangesLimits

/// Bounds of the `task-changes.v1` contract and the ceilings this client enforces on top of them.
/// A document that exceeds any of them is malformed and fails closed.
public enum TaskChangesLimits {
    /// Repositories captured per task.
    public static let maxRepositories = 8
    /// Scopes per repository (`committed_range`, `working_tree`).
    public static let maxScopesPerRepository = 2
    /// Rows stored per scope.
    public static let maxRowsPerScope = 500
    /// Client ceiling on the rows of one task: 8 repositories x 2 scopes x 500 rows.
    public static let maxRows = maxRepositories * maxScopesPerRepository * maxRowsPerScope
    /// Default and maximum `--limit` of a listing page.
    public static let defaultPageLimit = 200
    public static let maxPageLimit = 500
    /// Bytes of one printed document; the engine serves nothing larger.
    public static let maxDocumentBytes = 262_144
    /// Characters of an opaque cursor.
    public static let maxCursorCharacters = 2048
    /// Bytes of a row path; longer paths are stored truncated.
    public static let maxPathBytes = 4096
    /// JSON-escaped bytes of a provenance field before the engine cuts it and sets `fields_truncated`.
    public static let maxFieldEscapedBytes = 4096
    /// Reported conflict names per scope.
    public static let maxReportedConflicts = 100
    /// Stored text of one row: the engine retains at most 64 KiB per file.
    public static let maxTextBytes = 65_536
    /// Chunks of one row's text; the document bound and 64 KiB make more than a few unreachable.
    public static let maxTextChunks = 32
    /// JSON-escaped bytes of one scope's reported conflict names.
    public static let maxReportedConflictsEscapedBytes = 8192
    /// Restarts from the first page the repository allows after `changes_cursor_expired`.
    public static let maxRestarts = 2
    /// Requests (pages or chunks) one read may issue, across restarts.
    public static let maxRequestsPerRead = 64
    /// Wall-clock seconds one read may take, across restarts.
    public static let maxReadSeconds = 120
}

// MARK: - Open values

/// A wire string the contract enumerates today but may extend; an unknown value is kept verbatim,
/// never collapsed into a known one.
public struct TaskChangesState: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let available = TaskChangesState(rawValue: "available")
    public static let incomplete = TaskChangesState(rawValue: "incomplete")
    public static let unavailable = TaskChangesState(rawValue: "unavailable")
    public static let notCaptured = TaskChangesState(rawValue: "not_captured")
    public static let pending = TaskChangesState(rawValue: "pending")
}

/// A row's change kind, kept open.
public struct TaskChangesRowStatus: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let added = TaskChangesRowStatus(rawValue: "added")
    public static let modified = TaskChangesRowStatus(rawValue: "modified")
    public static let deleted = TaskChangesRowStatus(rawValue: "deleted")
    public static let typechange = TaskChangesRowStatus(rawValue: "typechange")
    public static let unmerged = TaskChangesRowStatus(rawValue: "unmerged")
    public static let submodule = TaskChangesRowStatus(rawValue: "submodule")
    public static let untracked = TaskChangesRowStatus(rawValue: "untracked")
    public static let unknown = TaskChangesRowStatus(rawValue: "unknown")
}

/// Whether a row's patch text was retained, kept open.
public struct TaskChangesContentState: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let available = TaskChangesContentState(rawValue: "available")
    public static let truncated = TaskChangesContentState(rawValue: "truncated")
    public static let binary = TaskChangesContentState(rawValue: "binary")
    public static let omittedSize = TaskChangesContentState(rawValue: "omitted_size")
    public static let notCaptured = TaskChangesContentState(rawValue: "not_captured")
}

/// A scope key of a repository, kept open; the selector wire spelling is the raw value.
public struct TaskChangesScopeName: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }

    public static let committedRange = TaskChangesScopeName(rawValue: "committed_range")
    public static let workingTree = TaskChangesScopeName(rawValue: "working_tree")

    fileprivate var order: Int {
        switch self {
        case .committedRange: return 0
        case .workingTree: return 1
        default: return 2
        }
    }
}

/// The per-repository `baseline_dirty` observation.
public enum TaskChangesBaselineDirty: Equatable, Sendable {
    case dirty, clean, unknown
    /// A string other than `"unknown"`, kept verbatim.
    case other(String)
}

// MARK: - TaskChangesFields

/// Required-key readers shared by the decoders; a missing key is a failure, an explicit `null` is not.
struct TaskChangesFields {
    let raw: [String: JSONValue]

    init(_ raw: [String: JSONValue]) { self.raw = raw }

    func string(_ key: String) -> String? {
        guard let value = raw[key]?.stringValue, Self.escapedBytes(value) <= TaskChangesLimits.maxFieldEscapedBytes else {
            return nil
        }
        return value
    }

    /// True when the key is present as a string within the bound or as `null`.
    func hasNullableString(_ key: String) -> Bool {
        raw[key] == .null || string(key) != nil
    }

    func bool(_ key: String) -> Bool? { raw[key]?.boolValue }

    func count(_ key: String) -> Int? {
        guard let value = raw[key]?.wireIntegerValue, value >= 0 else { return nil }
        return value
    }

    func hasNullableCount(_ key: String) -> Bool {
        raw[key] == .null || count(key) != nil
    }

    func object(_ key: String) -> [String: JSONValue]? { raw[key]?.objectValue }

    func array(_ key: String) -> [JSONValue]? { raw[key]?.arrayValue }

    /// Bytes of `value` as the engine prints it (ASCII-escaped JSON), without the quotes.
    static func escapedBytes(_ value: String) -> Int {
        value.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: return total + 2
            case 0 ..< 0x20, 0x7F: return total + 6
            case 0x20 ..< 0x7F: return total + 1
            case 0x80 ... 0xFFFF: return total + 6
            default: return total + 12
            }
        }
    }
}

// MARK: - TaskChangesPath

/// A path as stored: bytes, because a path need not be UTF-8.
public struct TaskChangesPath: Hashable, Sendable {
    public let bytes: Data

    public init?(bytes: Data) {
        guard bytes.count <= TaskChangesLimits.maxPathBytes else { return nil }
        self.bytes = bytes
    }

    /// The path when its bytes are valid UTF-8.
    public var utf8String: String? { String(data: bytes, encoding: .utf8) }

    /// A lossy rendering for display only; never use it to address a row.
    public var displayString: String { String(bytes: bytes, encoding: .utf8) ?? Self.lossyUTF8(bytes) }

    /// Replacement-character decoding of arbitrary bytes, for display only.
    static func lossyUTF8(_ data: Data) -> String {
        var result = String.UnicodeScalarView()
        var iterator = data.makeIterator()
        var codec = UTF8()
        decoding: while true {
            switch codec.decode(&iterator) {
            case .scalarValue(let scalar): result.append(scalar)
            case .emptyInput: break decoding
            case .error: result.append("\u{FFFD}")
            }
        }
        return String(result)
    }

    /// Decodes the `path` / `path_bytes_b64` pair, of which exactly one is non-null.
    init?(path: JSONValue?, encoded: JSONValue?) {
        switch (path, encoded) {
        case (.some(.string(let text)), .some(.null)):
            self.init(bytes: Data(text.utf8))
        case (.some(.null), .some(.string(let base64))):
            guard let data = Data(base64Encoded: base64) else { return nil }
            self.init(bytes: data)
        default:
            return nil
        }
    }
}

// MARK: - TaskChangesContent

/// A row's retained-text state and size.
public struct TaskChangesContent: Equatable, Sendable {
    public let state: TaskChangesContentState
    /// Open reason, such as `file_limit`, `untracked` or `capture_timeout`.
    public let reason: String?
    public let bytes: Int

    init?(raw: [String: JSONValue]) {
        let fields = TaskChangesFields(raw)
        guard let state = fields.string("state"), fields.hasNullableString("reason"), let bytes = fields.count("bytes") else { return nil }
        self.state = TaskChangesContentState(rawValue: state)
        reason = raw["reason"]?.stringValue
        self.bytes = bytes
    }
}

// MARK: - TaskChangesRow

/// One changed path of one scope. The row never carries patch text; read it with a selector.
public struct TaskChangesRow: Equatable, Sendable {
    public let path: TaskChangesPath
    /// True when the stored path is a cut form; such a row cannot be addressed.
    public let pathTruncated: Bool
    /// Always `null` in `task-changes.v1` (renames are off); an unexpected string is kept.
    public let oldPath: String?
    public let status: TaskChangesRowStatus
    /// `nil` for binary content.
    public let additions: Int?
    public let deletions: Int?
    public let binary: Bool
    public let content: TaskChangesContent

    init?(raw: [String: JSONValue]) {
        let fields = TaskChangesFields(raw)
        guard let path = TaskChangesPath(path: raw["path"], encoded: raw["path_bytes_b64"]),
              let truncated = fields.bool("path_truncated"), let binary = fields.bool("binary"),
              fields.hasNullableString("old_path"), let status = fields.string("status"),
              fields.hasNullableCount("additions"), fields.hasNullableCount("deletions"),
              let contentRaw = fields.object("content"), let content = TaskChangesContent(raw: contentRaw) else { return nil }
        self.path = path
        pathTruncated = truncated
        oldPath = raw["old_path"]?.stringValue
        self.status = TaskChangesRowStatus(rawValue: status)
        additions = raw["additions"]?.wireIntegerValue
        deletions = raw["deletions"]?.wireIntegerValue
        self.binary = binary
        self.content = content
    }
}

// MARK: - TaskChangesReportedConflicts

/// Advisory conflicted names taken from the agent's index; they never change a row.
public struct TaskChangesReportedConflicts: Equatable, Sendable {
    public let names: [TaskChangesPath]
    public let truncated: Bool

    /// True when no name was reported and none was cut off.
    public var isEmpty: Bool { names.isEmpty && !truncated }

    /// Bytes of one name as the engine prints it (`{"path": P, "path_bytes_b64": B}`, ASCII-escaped).
    private static func escapedSize(_ name: [String: JSONValue]) -> Int {
        func size(_ value: JSONValue?) -> Int {
            guard let text = value?.stringValue else { return 4 }
            return TaskChangesFields.escapedBytes(text) + 2
        }
        return 9 + size(name["path"]) + 20 + size(name["path_bytes_b64"]) + 1
    }

    init?(raw: [String: JSONValue]) {
        let fields = TaskChangesFields(raw)
        guard let truncated = fields.bool("truncated"), let entries = fields.array("names"),
              entries.count <= TaskChangesLimits.maxReportedConflicts else { return nil }
        var names: [TaskChangesPath] = []
        var escaped = 0
        for entry in entries {
            guard let object = entry.objectValue, let name = TaskChangesPath(path: object["path"], encoded: object["path_bytes_b64"]) else {
                return nil
            }
            escaped += Self.escapedSize(object) + 2
            names.append(name)
        }
        guard escaped <= TaskChangesLimits.maxReportedConflictsEscapedBytes else { return nil }
        self.names = names
        self.truncated = truncated
    }
}

// MARK: - TaskChangesScope

/// One observation (`committed_range` or `working_tree`) of one repository.
public struct TaskChangesScope: Equatable, Sendable {
    public let name: TaskChangesScopeName
    public let state: TaskChangesState
    /// Open reason.
    public let reason: String?
    /// Rows stored for the scope; `rows` holds those read so far.
    public let rowCount: Int
    public let rowsTruncated: Bool
    public let observedAt: String?
    public internal(set) var rows: [TaskChangesRow]
    /// Working tree only: counts and patch are separate observations and may disagree.
    public let countsAndPatchSeparate: Bool?
    /// Working tree only: `true` means the conflicts were not examined or could not be read.
    public let unmergedUnknown: Bool?
    public let reportedConflicts: TaskChangesReportedConflicts?

    init?(name: String, raw: [String: JSONValue]) {
        let fields = TaskChangesFields(raw)
        guard !name.isEmpty, let state = fields.string("state"), fields.hasNullableString("reason"),
              let rowCount = fields.count("row_count"), rowCount <= TaskChangesLimits.maxRowsPerScope,
              let truncated = fields.bool("rows_truncated"), fields.hasNullableString("observed_at"),
              let entries = fields.array("rows"), entries.count <= rowCount else { return nil }
        let rows = entries.compactMap { $0.objectValue.flatMap(TaskChangesRow.init(raw:)) }
        guard rows.count == entries.count else { return nil }
        let scopeName = TaskChangesScopeName(rawValue: name)
        var separate: Bool?
        var unmerged: Bool?
        var conflicts: TaskChangesReportedConflicts?
        if scopeName == .workingTree {
            guard let separateValue = fields.bool("counts_and_patch_separate"), let unmergedValue = fields.bool("unmerged_unknown"),
                  let conflictsRaw = fields.object("reported_conflicts"),
                  let conflictsValue = TaskChangesReportedConflicts(raw: conflictsRaw) else { return nil }
            separate = separateValue
            unmerged = unmergedValue
            conflicts = conflictsValue
        }
        self.name = scopeName
        self.state = TaskChangesState(rawValue: state)
        reason = raw["reason"]?.stringValue
        self.rowCount = rowCount
        rowsTruncated = truncated
        observedAt = raw["observed_at"]?.stringValue
        self.rows = rows
        countsAndPatchSeparate = separate
        unmergedUnknown = unmerged
        reportedConflicts = conflicts
    }
}

// MARK: - TaskChangesRepositoryEntry

/// One captured repository: provenance, state and its scopes.
public struct TaskChangesRepositoryEntry: Equatable, Sendable {
    /// The fixed non-authorship statement every repository carries.
    public static let attribution = "Observed repository differences; not evidence of task authorship."

    public let repositoryRoot: String?
    public let worktree: String?
    public let gitCommonDir: String?
    public let baseCommit: String?
    /// Open provenance, such as `dispatch`.
    public let baseProvenance: String?
    public let headCommit: String?
    public let observedAt: String?
    public let baselineDirty: TaskChangesBaselineDirty
    /// True when a provenance field above was cut; the repository root is then not a usable selector.
    public let fieldsTruncated: Bool
    public let state: TaskChangesState
    public let reason: String?
    /// Committed range first, then working tree, then any other scope by name.
    public internal(set) var scopes: [TaskChangesScope]

    private static let stringKeys = ["repository_root", "worktree", "git_common_dir", "base_commit", "base_provenance", "head_commit",
                                     "observed_at", "reason"]

    init?(raw: [String: JSONValue]) {
        let fields = TaskChangesFields(raw)
        guard Self.stringKeys.allSatisfy(fields.hasNullableString), raw["attribution"]?.stringValue == Self.attribution,
              let dirty = Self.baselineDirty(raw["baseline_dirty"]), let truncated = fields.bool("fields_truncated"),
              let state = fields.string("state"), let scopesRaw = fields.object("scopes"),
              scopesRaw.count <= TaskChangesLimits.maxScopesPerRepository else { return nil }
        var scopes: [TaskChangesScope] = []
        for (name, value) in scopesRaw {
            guard let object = value.objectValue, let scope = TaskChangesScope(name: name, raw: object) else { return nil }
            scopes.append(scope)
        }
        scopes.sort { ($0.name.order, $0.name.rawValue) < ($1.name.order, $1.name.rawValue) }
        repositoryRoot = raw["repository_root"]?.stringValue
        worktree = raw["worktree"]?.stringValue
        gitCommonDir = raw["git_common_dir"]?.stringValue
        baseCommit = raw["base_commit"]?.stringValue
        baseProvenance = raw["base_provenance"]?.stringValue
        headCommit = raw["head_commit"]?.stringValue
        observedAt = raw["observed_at"]?.stringValue
        baselineDirty = dirty
        fieldsTruncated = truncated
        self.state = TaskChangesState(rawValue: state)
        reason = raw["reason"]?.stringValue
        self.scopes = scopes
    }

    /// The scope with this name, if the repository carries it.
    public func scope(_ name: TaskChangesScopeName) -> TaskChangesScope? {
        scopes.first { $0.name == name }
    }

    /// Repository metadata and scope metadata without any rows, for comparing pages of one document.
    var strippingRows: TaskChangesRepositoryEntry {
        var copy = self
        copy.scopes = scopes.map { scope in
            var stripped = scope
            stripped.rows = []
            return stripped
        }
        return copy
    }

    private static func baselineDirty(_ value: JSONValue?) -> TaskChangesBaselineDirty? {
        switch value {
        case .some(.bool(let flag)): return flag ? .dirty : .clean
        case .some(.string("unknown")): return .unknown
        case .some(.string(let other)): return .other(other)
        default: return nil
        }
    }
}

// MARK: - TaskChangesCapture

/// The whole capture as one fact: `available` here says nothing about any repository.
public struct TaskChangesCapture: Equatable, Sendable {
    public let state: TaskChangesState
    /// Open reason, such as `task_running`, `capture_settling`, `no_repository` or `capture_timeout`; callers decide what a pending or non-null reason means.
    public let reason: String?

    init?(raw: [String: JSONValue]) {
        let fields = TaskChangesFields(raw)
        guard let state = fields.string("state"), fields.hasNullableString("reason") else { return nil }
        self.state = TaskChangesState(rawValue: state)
        reason = raw["reason"]?.stringValue
    }
}
