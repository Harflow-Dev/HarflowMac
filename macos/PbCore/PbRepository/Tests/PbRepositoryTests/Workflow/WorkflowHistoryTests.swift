import Mockable
import MonitorCore
@testable import PbRepository
import Testing

// MARK: - WorkflowHistoryTests

struct WorkflowHistoryTests {
    @Test func givenPagedSummaries_whenPollingHistory_thenOnlyOneBoundedActiveFirstPageIsFetched() async throws {
        // given
        let repository = MockWorkflowRepository()
        given(repository).command(.value("list-runs"), options: .value([]), positionals: .value([])).willReturn([
            "runs": .array([.object(["workflow_run_id": .string("active")])]), "next_offset": .number(100)
        ])
        // when
        let rows = try await repository.historySummaries()
        // then
        #expect(rows.compactMap { $0["workflow_run_id"]?.stringValue } == ["active"])
    }
}
