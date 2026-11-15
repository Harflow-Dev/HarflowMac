@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - StatisticsStatusIconTests

/// A ranking child row's status icon is the approved status set: done (the workflow glyph for a workflow fact), failed and
/// timed out as x, cancelled as the stop glyph, and none for any other status.
struct StatisticsStatusIconTests: StatisticsFixtures {

    @Test func givenCompletedTaskFact_whenProjected_thenItIsTheDoneCheck() {
        // given / when
        let icon = StatisticsProjection.statusIcon(execution("e", cohort: 0, status: "completed"))

        // then
        #expect(icon == StatisticsStatusIcon(status: .completed, kind: .task))
    }

    @Test func givenCompletedWorkflowFact_whenProjected_thenItIsTheWorkflowGlyph() {
        // given / when
        let icon = StatisticsProjection.statusIcon(workflow("w", cohort: 0, wall: 10))

        // then
        #expect(icon == StatisticsStatusIcon(status: .completed, kind: .workflowRun))
    }

    @Test(arguments: [("failed", TaskStatus.failed), ("timed_out", TaskStatus.timedOut)])
    func givenFailureOutcomes_whenProjected_thenTheyAreTheFailedFamilyWithTheirOwnStatus(raw: String, expected: TaskStatus) {
        // given / when
        let icon = StatisticsProjection.statusIcon(execution("e", cohort: 0, status: raw))

        // then
        #expect(icon == StatisticsStatusIcon(status: expected, kind: .task))
    }

    @Test func givenCancelledFact_whenProjected_thenItIsTheStopGlyphAndOtherStatusesDrawNone() {
        // given / when / then
        #expect(StatisticsProjection.statusIcon(execution("c", cohort: 0, status: "cancelled")) == StatisticsStatusIcon(status: .cancelled, kind: .task))
        #expect(StatisticsProjection.statusIcon(execution("r", cohort: 0, status: "running")) == nil)
    }
}
