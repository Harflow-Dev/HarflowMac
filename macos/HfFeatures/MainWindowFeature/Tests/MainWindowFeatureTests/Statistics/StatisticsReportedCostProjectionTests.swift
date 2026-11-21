import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

struct StatisticsReportedCostProjectionTests: StatisticsFixtures {
    @Test func givenCompleteReportedCosts_whenProjected_thenOverviewAndHarnessAmountsUseTheMatchingCohort() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = execution("one", cohort: now.timeIntervalSince1970, duration: 10, harness: "claude", cost: .reported(1.25))
        let second = execution("two", cohort: now.timeIntervalSince1970, duration: 10, harness: "claude", cost: .reported(2.25))
        let native = execution("native", cohort: now.timeIntervalSince1970, cost: .excluded)
        let source = snapshot(
            [first, second, native], costCoverage: StatisticsCostCoverage(eligibleExecutions: 2, availableExecutions: 2)
        )

        // when
        let result = StatisticsProjection.derive(snapshot: source, selection: StatisticsSelection(), now: now, calendar: calendar)

        // then
        #expect(result.reportedCost.value == "$3.50")
        #expect(result.reportedCost.coverage == "Reported by 2 of 2 executions")
        #expect(result.perHarnessCosts["harness:\"claude\""] == StatisticsCostPresentation(
            value: "$3.50", coverage: "Reported by 2 of 2 executions"
        ))
    }

    @Test func givenPartialOrUnqualifiedReportedCosts_whenProjected_thenUnavailableAndOnlyTrustedCoverageIsShown() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reported = execution("reported", cohort: now.timeIntervalSince1970, harness: "claude", cost: .reported(4.5))
        let silent = execution("silent", cohort: now.timeIntervalSince1970, harness: "codex", cost: .unavailable)
        let partial = snapshot(
            [reported, silent], costCoverage: StatisticsCostCoverage(eligibleExecutions: 2, availableExecutions: 1)
        )
        let unqualified = snapshot([reported, silent])

        // when
        let partialResult = StatisticsProjection.derive(
            snapshot: partial, selection: StatisticsSelection(), now: now, calendar: calendar
        )
        let unknownResult = StatisticsProjection.derive(
            snapshot: unqualified, selection: StatisticsSelection(), now: now, calendar: calendar
        )

        // then
        #expect(partialResult.reportedCost.value == "Unavailable")
        #expect(partialResult.reportedCost.coverage == "Reported by 1 of 2 executions")
        #expect(unknownResult.reportedCost.value == "Unavailable")
        #expect(unknownResult.reportedCost.coverage == "Cost coverage unavailable")
    }

    @Test func givenZeroOrTinyReportedCost_whenProjected_thenZeroAndSubCentRemainExplicit() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let zero = execution("zero", cohort: now.timeIntervalSince1970, harness: "claude", cost: .reported(0))
        let tiny = execution("tiny", cohort: now.timeIntervalSince1970, harness: "claude", cost: .reported(0.004))
        let roundedUp = execution("rounded", cohort: now.timeIntervalSince1970, harness: "claude", cost: .reported(0.005))

        // when
        let zeroResult = StatisticsProjection.derive(
            snapshot: snapshot([zero], costCoverage: StatisticsCostCoverage(eligibleExecutions: 1, availableExecutions: 1)),
            selection: StatisticsSelection(), now: now, calendar: calendar
        )
        let tinyResult = StatisticsProjection.derive(
            snapshot: snapshot([tiny], costCoverage: StatisticsCostCoverage(eligibleExecutions: 1, availableExecutions: 1)),
            selection: StatisticsSelection(), now: now, calendar: calendar
        )
        let roundedResult = StatisticsProjection.derive(
            snapshot: snapshot([roundedUp], costCoverage: StatisticsCostCoverage(eligibleExecutions: 1, availableExecutions: 1)),
            selection: StatisticsSelection(), now: now, calendar: calendar
        )

        // then
        #expect(zeroResult.reportedCost.value == "$0.00")
        #expect(tinyResult.reportedCost.value == "<$0.01")
        #expect(roundedResult.reportedCost.value == "$0.01")
    }

    @Test func givenQualifiedSnapshotWithNoEligibleExecutions_whenProjected_thenCoverageStatesZeroEligibility() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = workflow("root", cohort: now.timeIntervalSince1970, wall: 60)
        let source = snapshot(
            [root], costCoverage: StatisticsCostCoverage(eligibleExecutions: 0, availableExecutions: 0)
        )

        // when
        let result = StatisticsProjection.derive(snapshot: source, selection: StatisticsSelection(), now: now, calendar: calendar)

        // then
        #expect(result.reportedCost.value == "Unavailable")
        #expect(result.reportedCost.coverage == "No eligible executions")
    }

    @Test func givenHarnessFilter_whenProjected_thenReportedCostAndCoverageUseTheFilteredRows() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let claude = execution("claude", cohort: now.timeIntervalSince1970, harness: "claude", cost: .reported(0.75))
        let codex = execution("codex", cohort: now.timeIntervalSince1970, harness: "codex", cost: .reported(9))
        let source = snapshot(
            [claude, codex], costCoverage: StatisticsCostCoverage(eligibleExecutions: 2, availableExecutions: 2)
        )
        let selection = StatisticsSelection(harness: StatisticsProjection.identity(
            "claude", namespace: "harness", unknown: StatisticsProjection.unknownHarness
        ))

        // when
        let result = StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.reportedCost.value == "$0.75")
        #expect(result.reportedCost.coverage == "Reported by 1 of 1 executions")
        #expect(result.perHarnessCosts.count == 1)
    }

    @Test func givenUnknownHarness_whenProjected_thenPerHarnessReportedAmountStaysUnavailable() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let unknown = execution("unknown", cohort: now.timeIntervalSince1970, cost: .reported(3))

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([unknown], costCoverage: StatisticsCostCoverage(eligibleExecutions: 1, availableExecutions: 1)),
            selection: StatisticsSelection(), now: now, calendar: calendar
        )

        // then
        #expect(result.perHarnessCosts[StatisticsProjection.unknownHarness]?.value == "Unavailable")
        #expect(result.perHarnessCosts[StatisticsProjection.unknownHarness]?.coverage == "Reported by 1 of 1 executions")
    }

}
