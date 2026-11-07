import Foundation

// MARK: - TaskChangesAssemblyError

/// Why pages or chunks of one read could not be combined. Messages never contain diff text.
public enum TaskChangesAssemblyError: Error, Equatable, Sendable {
    case taskChanged
    case documentChanged
    case alreadyFinished
    case duplicateRow
    case rowLimitExceeded
    case noProgress
    case repeatedCursor
    case unfinished
    case rowCountMismatch
    case selectorMismatch
    case offsetMismatch
    case encodingChanged
    case sizeExceeded
    case tooManyChunks

    /// A fixed description.
    public var message: String {
        switch self {
        case .taskChanged: return "task-changes pages belong to different tasks"
        case .documentChanged: return "task-changes pages describe different documents"
        case .alreadyFinished: return "task-changes input after the last page"
        case .duplicateRow: return "task-changes scope repeats a row path"
        case .rowLimitExceeded: return "task-changes rows exceed the client ceiling"
        case .noProgress: return "task-changes page made no progress"
        case .repeatedCursor: return "task-changes cursor repeated"
        case .unfinished: return "task-changes read ended before the last page"
        case .rowCountMismatch: return "task-changes rows do not match the scope row count"
        case .selectorMismatch: return "task-changes text does not match the requested row"
        case .offsetMismatch: return "task-changes text chunks are not contiguous"
        case .encodingChanged: return "task-changes text encoding changed between chunks"
        case .sizeExceeded: return "task-changes text exceeds the client ceiling"
        case .tooManyChunks: return "task-changes text has too many chunks"
        }
    }
}

// MARK: - TaskChangesPage

/// One listing page: the capture, every repository's metadata, and the rows of this page only.
public struct TaskChangesPage: Equatable, Sendable {
    public let taskID: String
    public let capture: TaskChangesCapture
    public let repositories: [TaskChangesRepositoryEntry]
    public let limit: Int
    public let hasMore: Bool
    public let nextCursor: String?
    public let observedAt: String
    public let resolvedFrom: TaskEventResolvedFrom?

    /// Requires the exact listing shape and its bounds; rows of one page never exceed `limit`.
    public init?(raw: [String: JSONValue], requestedLimit: Int) {
        let fields = TaskChangesFields(raw)
        guard (1 ... TaskChangesLimits.maxPageLimit).contains(requestedLimit),
              let taskID = raw["task_id"]?.stringValue, !taskID.isEmpty, raw["mode"]?.stringValue == "list",
              let captureRaw = fields.object("capture"), let capture = TaskChangesCapture(raw: captureRaw),
              let repositoriesRaw = fields.array("repositories"), repositoriesRaw.count <= TaskChangesLimits.maxRepositories,
              raw["limit"]?.wireIntegerValue == requestedLimit, let hasMore = fields.bool("has_more"),
              let observed = raw["observed_at"]?.stringValue else { return nil }
        let repositories = repositoriesRaw.compactMap { $0.objectValue.flatMap(TaskChangesRepositoryEntry.init(raw:)) }
        guard repositories.count == repositoriesRaw.count,
              repositories.reduce(0, { $0 + $1.scopes.reduce(0) { $0 + $1.rows.count } }) <= requestedLimit,
              let cursor = Self.cursor(raw["next_cursor"], hasMore: hasMore) else { return nil }
        var resolution: TaskEventResolvedFrom?
        if let value = raw["resolved_from"] {
            guard let object = value.objectValue, let decoded = TaskEventResolvedFrom(raw: object) else { return nil }
            resolution = decoded
        }
        self.taskID = taskID
        self.capture = capture
        self.repositories = repositories
        limit = requestedLimit
        self.hasMore = hasMore
        nextCursor = cursor.value
        observedAt = observed
        resolvedFrom = resolution
    }

    /// `hasMore` and `next_cursor` must agree; the wrapper distinguishes "no cursor" from "invalid".
    static func cursor(_ value: JSONValue?, hasMore: Bool) -> CursorValue? {
        switch (value, hasMore) {
        case (.some(.null), false): return CursorValue(value: nil)
        case (.some(.string(let text)), true) where TaskEventPage.validCursor(text): return CursorValue(value: text)
        default: return nil
        }
    }

    struct CursorValue { let value: String? }
}

// MARK: - TaskChangesSnapshot

/// Why a snapshot cannot establish "nothing changed".
public enum TaskChangesGap: Equatable, Sendable {
    case captureNotAvailable(state: TaskChangesState, reason: String?)
    case repositoryNotAvailable(index: Int, state: TaskChangesState, reason: String?)
    case scopeMissing(repositoryIndex: Int, scope: TaskChangesScopeName)
    case scopeNotAvailable(repositoryIndex: Int, scope: TaskChangesScopeName, state: TaskChangesState, reason: String?)
    case rowsTruncated(repositoryIndex: Int, scope: TaskChangesScopeName)
    case unmergedUnknown(repositoryIndex: Int)
}

/// Derived completeness of a fully paged read, separate from any row's content state.
public struct TaskChangesCompleteness: Equatable, Sendable {
    /// True when `capture.state` is `available`, every repository and scope is `available`, no scope
    /// truncated its rows and no working tree left conflicts unexamined. The pages were all read to
    /// build the snapshot. Zero rows mean "no changes" only through `TaskChangesSnapshot.hasNoChanges`;
    /// `isComplete && totalRows == 0` is not enough (`no_repository`, a non-null capture reason and
    /// reported conflict names all disqualify it).
    public let isComplete: Bool
    public let gaps: [TaskChangesGap]

    init(capture: TaskChangesCapture, repositories: [TaskChangesRepositoryEntry]) {
        var gaps: [TaskChangesGap] = []
        if capture.state != .available { gaps.append(.captureNotAvailable(state: capture.state, reason: capture.reason)) }
        for (index, repository) in repositories.enumerated() {
            if repository.state != .available {
                gaps.append(.repositoryNotAvailable(index: index, state: repository.state, reason: repository.reason))
            }
            gaps.append(contentsOf: Self.scopeGaps(index: index, repository: repository))
        }
        self.gaps = gaps
        isComplete = gaps.isEmpty
    }

    private static func scopeGaps(index: Int, repository: TaskChangesRepositoryEntry) -> [TaskChangesGap] {
        var gaps: [TaskChangesGap] = []
        for name in [TaskChangesScopeName.committedRange, .workingTree] where repository.scope(name) == nil {
            gaps.append(.scopeMissing(repositoryIndex: index, scope: name))
        }
        for scope in repository.scopes {
            if scope.state != .available {
                gaps.append(.scopeNotAvailable(repositoryIndex: index, scope: scope.name, state: scope.state, reason: scope.reason))
            }
            if scope.rowsTruncated { gaps.append(.rowsTruncated(repositoryIndex: index, scope: scope.name)) }
            if scope.unmergedUnknown == true { gaps.append(.unmergedUnknown(repositoryIndex: index)) }
        }
        return gaps
    }
}

/// A listing read through its last page, with the rows of every page merged per scope.
public struct TaskChangesSnapshot: Equatable, Sendable {
    public let taskID: String
    public let capture: TaskChangesCapture
    public let repositories: [TaskChangesRepositoryEntry]
    /// The final page's observation time.
    public let observedAt: String
    public let pagesRead: Int
    public let completeness: TaskChangesCompleteness

    /// Rows across every repository and scope.
    public var totalRows: Int { repositories.reduce(0) { $0 + $1.scopes.reduce(0) { $0 + $1.rows.count } } }

    /// True only for a complete observation of at least one repository with no capture reason, zero
    /// rows and no reported conflict names (cut-off names included). Zero rows in anything less mean nothing.
    public var hasNoChanges: Bool {
        completeness.isComplete && !repositories.isEmpty && capture.reason == nil && totalRows == 0
            && repositories.allSatisfy { $0.scopes.allSatisfy { $0.reportedConflicts?.isEmpty ?? true } }
    }

    init(taskID: String, capture: TaskChangesCapture, repositories: [TaskChangesRepositoryEntry], observedAt: String, pagesRead: Int) {
        self.taskID = taskID
        self.capture = capture
        self.repositories = repositories
        self.observedAt = observedAt
        self.pagesRead = pagesRead
        completeness = TaskChangesCompleteness(capture: capture, repositories: repositories)
    }
}

// MARK: - TaskChangesListingBuilder

/// Merges consecutive pages of one document. Any inconsistency throws; a builder is single use.
public struct TaskChangesListingBuilder: Sendable {
    private var first: TaskChangesPage?
    private var merged: [TaskChangesRepositoryEntry] = []
    private var skeleton: [TaskChangesRepositoryEntry] = []
    private var seenCursors: Set<String> = []
    private var last: TaskChangesPage?
    private var pages = 0
    private var rows = 0
    private var paths: [[Set<Data>]] = []

    public init() {}

    /// The cursor to request next, or `nil` once the last page has been appended.
    public private(set) var nextCursor: String?

    /// Whether the last appended page ended the listing.
    public var isFinished: Bool { last.map { !$0.hasMore } ?? false }

    /// Appends the next page, in order.
    public mutating func append(_ page: TaskChangesPage) throws {
        guard !isFinished else { throw TaskChangesAssemblyError.alreadyFinished }
        let pageRows = page.repositories.reduce(0) { $0 + $1.scopes.reduce(0) { $0 + $1.rows.count } }
        guard rows + pageRows <= TaskChangesLimits.maxRows else { throw TaskChangesAssemblyError.rowLimitExceeded }
        guard !page.hasMore || pageRows > 0 else { throw TaskChangesAssemblyError.noProgress }
        if let cursor = page.nextCursor {
            guard seenCursors.insert(cursor).inserted else { throw TaskChangesAssemblyError.repeatedCursor }
        }
        if let first {
            guard page.taskID == first.taskID else { throw TaskChangesAssemblyError.taskChanged }
            guard page.capture == first.capture, page.repositories.map(\.strippingRows) == skeleton else {
                throw TaskChangesAssemblyError.documentChanged
            }
            try merge(page)
        } else {
            first = page
            skeleton = page.repositories.map(\.strippingRows)
            merged = page.repositories
            paths = page.repositories.map { $0.scopes.map { _ in Set<Data>() } }
            try registerPaths(of: page)
            try validateScopeRows()
        }
        last = page
        pages += 1
        rows += pageRows
        nextCursor = page.nextCursor
    }

    /// The merged snapshot; throws unless the last page was reached and every scope holds its stored rows.
    public func finish() throws -> TaskChangesSnapshot {
        guard let first, let last, !last.hasMore else { throw TaskChangesAssemblyError.unfinished }
        for repository in merged {
            for scope in repository.scopes where scope.rows.count != scope.rowCount {
                throw TaskChangesAssemblyError.rowCountMismatch
            }
        }
        return TaskChangesSnapshot(taskID: first.taskID, capture: first.capture, repositories: merged,
                                   observedAt: last.observedAt, pagesRead: pages)
    }

    private mutating func merge(_ page: TaskChangesPage) throws {
        for (index, repository) in page.repositories.enumerated() {
            for (scopeIndex, scope) in repository.scopes.enumerated() {
                merged[index].scopes[scopeIndex].rows.append(contentsOf: scope.rows)
            }
        }
        try registerPaths(of: page)
        try validateScopeRows()
    }

    /// Rejects a repeated, non-truncated path within one scope across all pages so far.
    private mutating func registerPaths(of page: TaskChangesPage) throws {
        for (index, repository) in page.repositories.enumerated() {
            for (scopeIndex, scope) in repository.scopes.enumerated() {
                for row in scope.rows where !row.pathTruncated {
                    guard paths[index][scopeIndex].insert(row.path.bytes).inserted else { throw TaskChangesAssemblyError.duplicateRow }
                }
            }
        }
    }

    private func validateScopeRows() throws {
        for repository in merged {
            for scope in repository.scopes where scope.rows.count > scope.rowCount {
                throw TaskChangesAssemblyError.rowCountMismatch
            }
        }
    }
}
