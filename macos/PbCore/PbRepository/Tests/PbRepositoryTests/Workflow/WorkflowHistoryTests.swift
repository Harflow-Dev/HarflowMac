import Mockable
import MonitorCore
@testable import PbRepository
import Testing

// MARK: - WorkflowHistoryTests

struct WorkflowHistoryTests {
    @Test func givenPagedSummaries_whenPollingHistory_thenOnlyOneBoundedActiveFirstPageIsFetched() async throws {
        // given
        let repository = MockWorkflowRepository()
        let page = try #require(HistoryPage(raw: ["items": .array([.object(["workflow_run_id": .string("active")])]),
            "next_cursor": .string("next"), "has_more": .bool(true), "bootstrap_pending": .bool(false)]))
        given(repository).historyPage(cursor: .value(nil), activeOnly: .value(true), relatedRunID: .value(nil)).willReturn(page)
        // when
        let rows = try await repository.historySummaries()
        // then
        #expect(rows.compactMap { $0["workflow_run_id"]?.stringValue } == ["active"])
    }
}
