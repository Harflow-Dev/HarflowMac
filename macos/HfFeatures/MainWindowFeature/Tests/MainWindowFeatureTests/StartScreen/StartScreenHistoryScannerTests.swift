import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - StartScreenHistoryScannerTests

final class FakeStartScreenHistorySource: StartScreenHistorySource, @unchecked Sendable {
    var taskPages: [String?: [String: JSONValue]]
    var workflowPages: [String?: [String: JSONValue]]

    init(taskPages: [String?: [String: JSONValue]] = [:], workflowPages: [String?: [String: JSONValue]] = [:]) {
        self.taskPages = taskPages
        self.workflowPages = workflowPages
    }

    func taskPage(cursor: String?) async throws -> TaskHistoryPage {
        guard let raw = taskPages[cursor], let page = TaskHistoryPage(raw: raw) else { throw FakeError.missingPage }
        return page
    }

    func workflowPage(cursor: String?) async throws -> HistoryPage {
        guard let raw = workflowPages[cursor], let page = HistoryPage(raw: raw) else { throw FakeError.missingPage }
        return page
    }

    func definitions() async throws -> [WorkflowRecord] { [] }

    enum FakeError: Error { case missingPage }
}

@Suite struct StartScreenHistoryScannerTests {
    private func page(items: [[String: JSONValue]], hasMore: Bool = false, cursor: String? = nil,
                      ready: Bool = true, bootstrap: Bool = false, historyIncomplete: Bool = false,
                      authorityIncomplete: Bool = false, countsComplete: Bool = true,
                      related: [[String: JSONValue]] = []) -> [String: JSONValue] {
        [
            "items": .array(items.map(JSONValue.object)), "related_headers": .array(related.map(JSONValue.object)),
            "has_more": .bool(hasMore), "next_cursor": cursor.map(JSONValue.string) ?? .null,
            "bootstrap_pending": .bool(bootstrap), "history_incomplete": .bool(historyIncomplete),
            "authority_incomplete": .bool(authorityIncomplete), "counts_complete": .bool(countsComplete),
            "total_active_count": .number(0),
            "catalog_state": .object(["status": .string(ready ? "ready" : "preparing")])
        ]
    }

    private func task(_ id: String, value: String = "one") -> [String: JSONValue] {
        ["task_id": .string(id), "status": .string("completed"), "payload": .string(value)]
    }

    private func workflow(_ id: String, value: String = "one") -> [String: JSONValue] {
        ["workflow_run_id": .string(id), "status": .string("completed"), "payload": .string(value)]
    }

    @Test func givenMultipleTaskPagesWithAnIdenticalOverlap_whenScanned_thenReturnsUniquePrimaryRows() async throws {
        // given
        let source = FakeStartScreenHistorySource(taskPages: [
            nil: page(items: [task("a"), task("b")], hasMore: true, cursor: "next"),
            "next": page(items: [task("b"), task("c")])
        ])

        // when
        let tasks = try await StartScreenHistoryScanner(source: source).scanTasks()

        // then
        #expect(Set(tasks.map(\.id)) == ["a", "b", "c"])
    }

    @Test func givenWorkflowPagesAndRelatedHeaders_whenScanned_thenCountsOnlyUniquePrimaryRuns() async throws {
        // given
        let source = FakeStartScreenHistorySource(workflowPages: [
            nil: page(items: [workflow("a")], hasMore: true, cursor: "next", related: [workflow("detail")]),
            "next": page(items: [workflow("b")], related: [workflow("detail")])
        ])

        // when
        let runs = try await StartScreenHistoryScanner(source: source).scanWorkflows()

        // then
        #expect(Set(runs.compactMap { $0["workflow_run_id"]?.stringValue }) == ["a", "b"])
    }

    @Test(arguments: ["preparing", "bootstrap", "history", "authority", "counts"])
    func givenAnyReadinessOrCompletenessFlagIsUnavailable_whenScanned_thenRejectsTheWholeResult(_ flag: String) async {
        // given
        let source = FakeStartScreenHistorySource(workflowPages: [nil: page(
            items: [workflow("a")], ready: flag != "preparing", bootstrap: flag == "bootstrap",
            historyIncomplete: flag == "history", authorityIncomplete: flag == "authority", countsComplete: flag != "counts"
        )])

        // when / then
        if flag == "preparing" {
            await #expect(throws: StartScreenHistoryScanner.ScanError.preparing) {
                try await StartScreenHistoryScanner(source: source).scanWorkflows()
            }
        } else {
            await #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
                try await StartScreenHistoryScanner(source: source).scanWorkflows()
            }
        }
    }

    @Test func givenARepeatedCursor_whenScanned_thenRejectsInsteadOfLooping() async {
        // given
        let repeated = page(items: [], hasMore: true, cursor: "same")
        let source = FakeStartScreenHistorySource(workflowPages: [nil: repeated, "same": repeated])

        // when / then
        await #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
            try await StartScreenHistoryScanner(source: source, pageLimit: 5).scanWorkflows()
        }
    }

    @Test func givenAWorkflowIdRepearsWithConflictingPayload_whenScanned_thenRejectsTheWholeResult() async {
        // given
        let source = FakeStartScreenHistorySource(workflowPages: [
            nil: page(items: [workflow("same")], hasMore: true, cursor: "next"),
            "next": page(items: [workflow("same", value: "changed")])
        ])

        // when / then
        await #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
            try await StartScreenHistoryScanner(source: source).scanWorkflows()
        }
    }

    @Test func givenRecordBudgetIsExceeded_whenScanned_thenRejectsRatherThanReturningPartialHistory() async {
        // given
        let source = FakeStartScreenHistorySource(workflowPages: [nil: page(items: [workflow("a"), workflow("b")])])

        // when / then
        await #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
            try await StartScreenHistoryScanner(source: source, recordLimit: 1).scanWorkflows()
        }
    }

    @Test func givenPageBudgetIsExceeded_whenScanned_thenRejectsRatherThanReturningPartialHistory() async {
        // given
        let source = FakeStartScreenHistorySource(workflowPages: [
            nil: page(items: [], hasMore: true, cursor: "second"),
            "second": page(items: [workflow("a")], hasMore: true, cursor: "third"),
            "third": page(items: [workflow("b")])
        ])

        // when / then
        await #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
            try await StartScreenHistoryScanner(source: source, pageLimit: 2).scanWorkflows()
        }
    }

    @Test func givenAConflictingTaskDuplicateAcrossPages_whenScanned_thenRejectsTheWholeResult() async {
        // given
        let source = FakeStartScreenHistorySource(taskPages: [
            nil: page(items: [task("same")], hasMore: true, cursor: "next"),
            "next": page(items: [task("same", value: "changed")])
        ])

        // when / then
        await #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
            try await StartScreenHistoryScanner(source: source).scanTasks()
        }
    }

    @Test func givenTaskHistoryReadIsIncomplete_whenScanned_thenRejectsTheWholeResult() async {
        // given
        let source = FakeStartScreenHistorySource(taskPages: [nil: page(items: [task("a")], authorityIncomplete: true)])

        // when / then
        await #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
            try await StartScreenHistoryScanner(source: source).scanTasks()
        }
    }

    @Test func givenTaskRecordBudgetIsExceeded_whenScanned_thenRejectsRatherThanReturningPartialHistory() async {
        // given
        let source = FakeStartScreenHistorySource(taskPages: [nil: page(items: [task("a"), task("b")])])

        // when / then
        await #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
            try await StartScreenHistoryScanner(source: source, recordLimit: 1).scanTasks()
        }
    }

    @Test(arguments: [
        ["catalog_state": JSONValue.object(["status": .string("ready")])],
        ["catalog_state": .object(["status": .string("ready")]), "workflows": .string("not-an-array")],
        ["catalog_state": .object(["status": .string("preparing")]), "workflows": .array([])],
        ["catalog_state": .object(["status": .string("ready")]), "workflows": .array([.string("malformed")])],
        ["catalog_state": .object(["status": .string("ready")]), "workflows": .array([.object(["name": .string(" ")])])],
        ["catalog_state": .object(["status": .string("ready")]), "workflows": .array([
            .object(["name": .string("Repeated")]), .object(["name": .string("Repeated")])
        ])]
    ])
    func givenDefinitionCatalogIsMissingPreparingOrMalformed_whenParsed_thenRejectsInsteadOfTreatingItAsEmpty(
        _ response: [String: JSONValue]
    ) {
        // given / when / then
        #expect(throws: StartScreenHistoryScanner.ScanError.self) {
            try StartScreenHistoryRepository.parseDefinitions(response: response)
        }
    }

    @Test func givenAValidEmptyDefinitionCatalog_whenParsed_thenReturnsAnEmptySavedList() throws {
        // given
        let response: [String: JSONValue] = [
            "catalog_state": .object(["status": .string("ready")]), "workflows": .array([])
        ]

        // when
        let definitions = try StartScreenHistoryRepository.parseDefinitions(response: response)

        // then
        #expect(definitions.isEmpty)
    }
}
