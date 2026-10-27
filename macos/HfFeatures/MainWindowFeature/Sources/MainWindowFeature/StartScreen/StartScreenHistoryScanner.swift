import Foundation
import HfRepository
import MonitorCore

protocol StartScreenHistorySource: Sendable {
    func taskPage(cursor: String?) async throws -> TaskHistoryPage
    func workflowPage(cursor: String?) async throws -> HistoryPage
    func definitions() async throws -> [WorkflowRecord]
}

struct StartScreenHistoryScanner: Sendable {
    var source: any StartScreenHistorySource
    var pageLimit = 100
    var recordLimit = 10_000
    var timeout: Duration = .seconds(30)

    func scanTasks() async throws -> [TaskInfo] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var records: [String: TaskInfo] = [:]
        var received = 0
        var cursor: String?
        var cursors: Set<String> = []
        for _ in 0 ..< pageLimit {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ScanError.incomplete }
            let response = try await source.taskPage(cursor: cursor)
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ScanError.incomplete }
            try check(response.page)
            received += response.items.count
            guard received <= recordLimit else { throw ScanError.incomplete }
            for item in response.items {
                if let existing = records[item.id], existing != item { throw ScanError.incomplete }
                records[item.id] = item
            }
            guard records.count <= recordLimit else { throw ScanError.incomplete }
            if !response.page.hasMore { return Array(records.values) }
            guard let next = response.page.nextCursor, !next.isEmpty, cursors.insert(next).inserted else { throw ScanError.incomplete }
            cursor = next
        }
        throw ScanError.incomplete
    }

    func scanWorkflows() async throws -> [[String: JSONValue]] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var records: [String: [String: JSONValue]] = [:]
        var received = 0
        var cursor: String?
        var cursors: Set<String> = []
        for _ in 0 ..< pageLimit {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ScanError.incomplete }
            let page = try await source.workflowPage(cursor: cursor)
            try Task.checkCancellation()
            guard clock.now < deadline else { throw ScanError.incomplete }
            try check(page)
            received += page.items.count
            guard received <= recordLimit else { throw ScanError.incomplete }
            for item in page.items {
                guard let id = item["workflow_run_id"]?.stringValue, !id.isEmpty else { throw ScanError.incomplete }
                if let existing = records[id], existing != item { throw ScanError.incomplete }
                records[id] = item
            }
            guard records.count <= recordLimit else { throw ScanError.incomplete }
            if !page.hasMore { return Array(records.values) }
            guard let next = page.nextCursor, !next.isEmpty, cursors.insert(next).inserted else { throw ScanError.incomplete }
            cursor = next
        }
        throw ScanError.incomplete
    }

    private func check(_ page: HistoryPage) throws {
        if page.catalogState.status == .preparing { throw ScanError.preparing }
        guard page.catalogState.isReady, !page.bootstrapPending, !page.historyIncomplete,
              !page.authorityIncomplete, page.countsComplete else { throw ScanError.incomplete }
    }

    enum ScanError: Error { case incomplete, preparing }
}

struct StartScreenHistoryRepository: StartScreenHistorySource {
    let tools: any ToolEnvironmentRepository
    let workflows: any WorkflowRepository

    func taskPage(cursor: String?) async throws -> TaskHistoryPage {
        let client = try tools.ctl().get()
        return try await client.taskHistoryPage(cursor: cursor).get()
    }

    func workflowPage(cursor: String?) async throws -> HistoryPage {
        try await workflows.historyPage(cursor: cursor, activeOnly: false, relatedRunID: nil)
    }

    func definitions() async throws -> [WorkflowRecord] {
        let response = try await workflows.command("list", options: [], positionals: [])
        return try Self.parseDefinitions(response: response)
    }

    static func parseDefinitions(response: [String: JSONValue]) throws -> [WorkflowRecord] {
        if CatalogState(raw: response).status == .preparing { throw StartScreenHistoryScanner.ScanError.preparing }
        guard CatalogState(raw: response).isReady else { throw StartScreenHistoryScanner.ScanError.incomplete }
        guard let items = response["workflows"]?.arrayValue else { throw StartScreenHistoryScanner.ScanError.incomplete }
        var names: Set<String> = []
        return try items.map { value in
            guard let object = value.objectValue, let name = object["name"]?.stringValue,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, names.insert(name).inserted else {
                throw StartScreenHistoryScanner.ScanError.incomplete
            }
            return WorkflowRecord(raw: object)
        }
    }
}
