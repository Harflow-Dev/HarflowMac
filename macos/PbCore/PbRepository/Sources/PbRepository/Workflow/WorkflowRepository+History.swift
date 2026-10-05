import MonitorCore

public extension WorkflowRepository {
    /// Bounded active inventory for status surfaces; history has a separate explicit cursor.
    func historySummaries() async throws -> [[String: JSONValue]] {
        try await historyPage(cursor: nil, activeOnly: true, relatedRunID: nil).items
    }
}
