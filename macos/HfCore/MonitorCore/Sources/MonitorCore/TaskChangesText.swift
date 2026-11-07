import Foundation

// MARK: - TaskChangesSelector

/// The address of one row: repository root, scope and the row's exact path bytes.
public struct TaskChangesSelector: Equatable, Hashable, Sendable {
    public let repositoryRoot: String
    public let scope: TaskChangesScopeName
    public let pathBytes: Data

    /// Fails for empty or NUL-bearing parts and for paths over the contract bound.
    public init?(repositoryRoot: String, scope: TaskChangesScopeName, pathBytes: Data) {
        guard !repositoryRoot.isEmpty, !repositoryRoot.contains("\0"), !scope.rawValue.isEmpty, !scope.rawValue.contains("\0"),
              (1 ... TaskChangesLimits.maxPathBytes).contains(pathBytes.count) else { return nil }
        self.repositoryRoot = repositoryRoot
        self.scope = scope
        self.pathBytes = pathBytes
    }

    /// The selector of a listed row, or `nil` when an identity field is genuinely incomplete:
    /// `fields_truncated` on the repository or `path_truncated` on the row. Content state
    /// (untracked, binary, not captured) never makes a row non-addressable.
    public init?(repository: TaskChangesRepositoryEntry, scope: TaskChangesScopeName, row: TaskChangesRow) {
        guard !repository.fieldsTruncated, !row.pathTruncated, let root = repository.repositoryRoot else { return nil }
        self.init(repositoryRoot: root, scope: scope, pathBytes: row.path.bytes)
    }
}

// MARK: - TaskChangesTextEncoding

/// How the engine carried the stored patch: valid UTF-8 as `text`, anything else as `text_b64`.
public enum TaskChangesTextEncoding: Equatable, Sendable {
    case utf8, base64
}

// MARK: - TaskChangesTextChunk

/// One chunk of a row's stored patch. Bytes are exact; a `text_b64` chunk may end inside a character.
public struct TaskChangesTextChunk: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let taskID: String
    public let capture: TaskChangesCapture
    public let repositoryRoot: String
    public let scope: TaskChangesScopeName
    public let path: TaskChangesPath
    public let pathTruncated: Bool
    public let status: TaskChangesRowStatus
    public let additions: Int?
    public let deletions: Int?
    public let binary: Bool
    public let content: TaskChangesContent
    public let bytes: Data
    public let encoding: TaskChangesTextEncoding
    public let offset: Int
    public let totalBytes: Int
    public let hasMore: Bool
    public let nextCursor: String?
    public let observedAt: String
    public let resolvedFrom: TaskEventResolvedFrom?

    /// Requires the exact text-mode shape; exactly one of `text` and `text_b64` carries the bytes.
    public init?(raw: [String: JSONValue]) {
        let fields = TaskChangesFields(raw)
        guard let taskID = raw["task_id"]?.stringValue, !taskID.isEmpty, raw["mode"]?.stringValue == "text",
              let captureRaw = fields.object("capture"), let capture = TaskChangesCapture(raw: captureRaw),
              let root = fields.string("repository_root"), let scope = raw["scope"]?.stringValue, !scope.isEmpty,
              let path = TaskChangesPath(path: raw["path"], encoded: raw["path_bytes_b64"]),
              let pathTruncated = fields.bool("path_truncated"), let status = fields.string("status"),
              fields.hasNullableCount("additions"), fields.hasNullableCount("deletions"), let binary = fields.bool("binary"),
              let contentRaw = fields.object("content"), let content = TaskChangesContent(raw: contentRaw),
              let payload = Self.payload(raw), let offset = fields.count("offset"), raw["returned_bytes"]?.wireIntegerValue == payload.0.count,
              let total = fields.count("total_bytes"), total <= TaskChangesLimits.maxTextBytes, content.bytes == total, offset + payload.0.count <= total,
              let hasMore = fields.bool("has_more"), hasMore == (offset + payload.0.count < total), !hasMore || !payload.0.isEmpty,
              let cursor = TaskChangesPage.cursor(raw["next_cursor"], hasMore: hasMore),
              let observed = raw["observed_at"]?.stringValue else { return nil }
        var resolution: TaskEventResolvedFrom?
        if let value = raw["resolved_from"] {
            guard let object = value.objectValue, let decoded = TaskEventResolvedFrom(raw: object) else { return nil }
            resolution = decoded
        }
        self.taskID = taskID
        self.capture = capture
        repositoryRoot = root
        self.scope = TaskChangesScopeName(rawValue: scope)
        self.path = path
        self.pathTruncated = pathTruncated
        self.status = TaskChangesRowStatus(rawValue: status)
        additions = raw["additions"]?.wireIntegerValue
        deletions = raw["deletions"]?.wireIntegerValue
        self.binary = binary
        self.content = content
        bytes = payload.0
        encoding = payload.1
        self.offset = offset
        totalBytes = total
        self.hasMore = hasMore
        nextCursor = cursor.value
        observedAt = observed
        resolvedFrom = resolution
    }

    /// Never prints patch text.
    public var description: String { "TaskChangesTextChunk(\(bytes.count) bytes at \(offset) of \(totalBytes))" }
    public var debugDescription: String { description }

    private static func payload(_ raw: [String: JSONValue]) -> (Data, TaskChangesTextEncoding)? {
        switch (raw["text"], raw["text_b64"]) {
        case (.some(.string(let text)), .some(.null)): return (Data(text.utf8), .utf8)
        case (.some(.null), .some(.string(let base64))):
            guard let data = Data(base64Encoded: base64) else { return nil }
            return (data, .base64)
        default: return nil
        }
    }
}

// MARK: - TaskChangesPatch

/// A row's complete stored patch, as exact bytes. Diff text is never persisted or logged by this client.
public struct TaskChangesPatch: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let taskID: String
    public let capture: TaskChangesCapture
    public let selector: TaskChangesSelector
    public let status: TaskChangesRowStatus
    public let additions: Int?
    public let deletions: Int?
    public let binary: Bool
    public let content: TaskChangesContent
    public let bytes: Data
    public let encoding: TaskChangesTextEncoding
    public let observedAt: String

    /// The patch as text when it is valid UTF-8.
    public var utf8String: String? { String(data: bytes, encoding: .utf8) }

    /// A lossy rendering for display only; the bytes stay authoritative.
    public var displayString: String { String(bytes: bytes, encoding: .utf8) ?? TaskChangesPath.lossyUTF8(bytes) }

    /// Never prints patch text.
    public var description: String { "TaskChangesPatch(\(bytes.count) bytes)" }
    public var debugDescription: String { description }
}

// MARK: - TaskChangesTextAssembler

/// Joins the chunks of one row's patch. Any gap, overlap, encoding switch or echo mismatch throws.
public struct TaskChangesTextAssembler: Sendable {
    public let selector: TaskChangesSelector
    /// The cursor to request next, or `nil` once the last chunk has been appended.
    public private(set) var nextCursor: String?
    private var first: TaskChangesTextChunk?
    private var last: TaskChangesTextChunk?
    private var bytes = Data()
    private var chunks = 0
    private var seenCursors: Set<String> = []

    public init(selector: TaskChangesSelector) { self.selector = selector }

    private var isFinished: Bool { last.map { !$0.hasMore } ?? false }

    /// Appends the next chunk, in order.
    public mutating func append(_ chunk: TaskChangesTextChunk) throws {
        guard !isFinished else { throw TaskChangesAssemblyError.alreadyFinished }
        guard chunk.repositoryRoot == selector.repositoryRoot, chunk.scope == selector.scope,
              chunk.path.bytes == selector.pathBytes, !chunk.pathTruncated else { throw TaskChangesAssemblyError.selectorMismatch }
        guard chunks < TaskChangesLimits.maxTextChunks else { throw TaskChangesAssemblyError.tooManyChunks }
        guard chunk.offset == bytes.count else { throw TaskChangesAssemblyError.offsetMismatch }
        guard bytes.count + chunk.bytes.count <= TaskChangesLimits.maxTextBytes else { throw TaskChangesAssemblyError.sizeExceeded }
        if let cursor = chunk.nextCursor {
            guard seenCursors.insert(cursor).inserted else { throw TaskChangesAssemblyError.repeatedCursor }
        }
        if let first { try Self.requireSameRow(chunk, as: first) } else { first = chunk }
        bytes.append(chunk.bytes)
        chunks += 1
        last = chunk
        nextCursor = chunk.nextCursor
    }

    private static func requireSameRow(_ chunk: TaskChangesTextChunk, as first: TaskChangesTextChunk) throws {
        guard chunk.taskID == first.taskID else { throw TaskChangesAssemblyError.taskChanged }
        guard chunk.encoding == first.encoding else { throw TaskChangesAssemblyError.encodingChanged }
        guard chunk.totalBytes == first.totalBytes, chunk.capture == first.capture, chunk.status == first.status,
              chunk.additions == first.additions, chunk.deletions == first.deletions, chunk.binary == first.binary,
              chunk.content == first.content else { throw TaskChangesAssemblyError.documentChanged }
    }

    /// The whole patch; throws unless the final chunk was appended and the byte count equals the total.
    public func finish() throws -> TaskChangesPatch {
        guard let first, let last, !last.hasMore else { throw TaskChangesAssemblyError.unfinished }
        guard bytes.count == first.totalBytes else { throw TaskChangesAssemblyError.offsetMismatch }
        return TaskChangesPatch(taskID: first.taskID, capture: first.capture, selector: selector, status: first.status,
                                additions: first.additions, deletions: first.deletions, binary: first.binary,
                                content: first.content, bytes: bytes, encoding: first.encoding, observedAt: last.observedAt)
    }
}
