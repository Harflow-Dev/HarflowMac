import Foundation

/// One bounded catalog page. Cursor identity belongs to the CLI, never to a row offset.
public struct HistoryPage: Equatable, Sendable {
    public let catalogState: CatalogState
    public let items: [[String: JSONValue]]
    public let relatedHeaders: [[String: JSONValue]]
    public let nextCursor: String?
    public let hasMore: Bool
    public let bootstrapPending: Bool
    public let historyIncomplete: Bool
    public let authorityIncomplete: Bool
    public let totalActiveRootCount: Int?
    public let totalAttentionRootCount: Int?
    public let countsComplete: Bool
    public let totalActiveCount: Int

    public init?(raw: [String: JSONValue]) {
        guard let values = raw["items"]?.arrayValue, values.count <= 100,
              let hasMore = raw["has_more"]?.boolValue,
              let bootstrap = raw["bootstrap_pending"]?.boolValue,
              raw["next_cursor"] == .null || raw["next_cursor"]?.stringValue != nil else { return nil }
        var items: [[String: JSONValue]] = []
        for value in values {
            guard let item = value.objectValue else { return nil }
            items.append(item)
        }
        let cursor = raw["next_cursor"]?.stringValue
        guard !hasMore || cursor?.isEmpty == false || bootstrap else { return nil }
        catalogState = CatalogState(raw: raw)
        self.items = items
        let related = raw["related_headers"]?.arrayValue ?? []
        guard related.count <= 100 else { return nil }
        var headers: [[String: JSONValue]] = []
        for value in related {
            guard let header = value.objectValue else { return nil }
            headers.append(header)
        }
        relatedHeaders = headers
        nextCursor = cursor
        self.hasMore = hasMore
        bootstrapPending = bootstrap
        historyIncomplete = raw["history_incomplete"]?.boolValue ?? false
        authorityIncomplete = raw["authority_incomplete"]?.boolValue ?? false
        countsComplete = (raw["counts_complete"]?.boolValue ?? !bootstrap) && raw["total_active_count"] != .null
        totalActiveRootCount = raw["total_active_root_count"]?.intValue
        totalAttentionRootCount = raw["total_attention_root_count"]?.intValue
        totalActiveCount = raw["total_active_count"]?.intValue ?? 0
    }
}

public struct TaskHistoryPage: Equatable, Sendable {
    public let page: HistoryPage
    public let items: [TaskInfo]
    public let relatedItems: [TaskInfo]
    public init?(raw: [String: JSONValue]) {
        guard let page = HistoryPage(raw: raw) else { return nil }
        let tasks = page.items.compactMap { TaskInfo(.object($0)) }
        let related = page.relatedHeaders.compactMap { TaskInfo(.object($0)) }
        guard tasks.count == page.items.count, related.count == page.relatedHeaders.count else { return nil }
        self.page = page
        items = tasks
        relatedItems = related
    }
}

public extension CtlClient {
    func taskHistoryPage(cursor: String? = nil, limit: Int = 100,
                         sessionID: String? = nil, activeOnly: Bool = false, taskIDs: [String] = []) async -> Result<TaskHistoryPage, ToolError> {
        var options = ["--limit=\(min(100, max(1, limit)))"]
        if let cursor { options.append("--cursor=\(cursor)") }
        if let sessionID { options.append("--session-id=\(sessionID)") }
        if !taskIDs.isEmpty { options.append("--task-ids=\(taskIDs.prefix(100).joined(separator: ","))") }
        if activeOnly { options.append("--active-only") }
        return await result("task-list-page", options: options).flatMap { raw in
            guard let page = TaskHistoryPage(raw: raw) else {
                return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "Malformed task history page"))
            }
            return .success(page)
        }
    }

    func workflowHistoryPage(cursor: String? = nil, limit: Int = 100,
                             activeOnly: Bool = false, relatedRunID: String? = nil, runIDs: [String] = []) async -> Result<HistoryPage, ToolError> {
        var options = ["--limit=\(min(100, max(1, limit)))"]
        if let cursor { options.append("--cursor=\(cursor)") }
        if activeOnly { options.append("--active-only") }
        if let relatedRunID { options.append("--related-run-id=\(relatedRunID)") }
        if !runIDs.isEmpty { options.append("--run-ids=\(runIDs.prefix(100).joined(separator: ","))") }
        return await result("workflow-list-page", options: options).flatMap { raw in
            guard let page = HistoryPage(raw: raw) else {
                return .failure(.unreadable(tool: "polybridge-ctl", exitCode: 0, stderr: "Malformed workflow history page"))
            }
            return .success(page)
        }
    }
}
