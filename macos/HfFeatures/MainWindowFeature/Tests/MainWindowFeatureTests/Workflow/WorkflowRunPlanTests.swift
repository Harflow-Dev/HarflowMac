@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowRunPlanTests

struct WorkflowRunPlanTests {
    @Test func givenRunTasks_whenPlanProjected_thenOnlyCompletedStatusCountsAsDone() {
        // given
        let tasks: [[String: JSONValue]] = [
            ["id": .string("one"), "status": .string("completed")],
            ["id": .string("two"), "status": .string("running")],
            ["id": .string("three"), "status": .string("needs_attention")],
            ["id": .string("four"), "status": .string("pending")]
        ]
        // when / then — the existing completed-status definition, nothing broader.
        #expect(WorkflowPlanProgress.completedCount(tasks) == 1)
        #expect(WorkflowPlanProgress.completedCount([]) == 0)
    }

    @Test func givenCompletedAndTotal_whenFractionProjected_thenValueIsClampedAndHonest() {
        // given / when / then
        #expect(WorkflowPlanProgress.fraction(completed: 0, total: 0) == 0)
        #expect(WorkflowPlanProgress.fraction(completed: 1, total: 2) == 0.5)
        #expect(WorkflowPlanProgress.fraction(completed: 2, total: 2) == 1)
        #expect(WorkflowPlanProgress.fraction(completed: 5, total: 2) == 1)
        #expect(WorkflowPlanProgress.fraction(completed: -1, total: 2) == 0)
    }
}
