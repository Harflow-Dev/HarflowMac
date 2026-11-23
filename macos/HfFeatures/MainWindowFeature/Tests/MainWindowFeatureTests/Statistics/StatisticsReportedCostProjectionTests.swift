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

    private func costResult(
        _ facts: [StatisticsFact], eligible: Int, available: Int, selection: StatisticsSelection = StatisticsSelection(),
        qualified: Bool = true
    ) -> StatisticsPresentation {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = qualified
            ? snapshot(facts, costCoverage: StatisticsCostCoverage(eligibleExecutions: eligible, availableExecutions: available))
            : snapshot(facts)
        return StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)
    }

    private var cohort: Double { 1_800_000_000 }

    @Test func givenPartialReportedCosts_whenProjected_thenTotalOfReportedAndPartialCoverageAreShown() {
        // given
        let one = execution("one", cohort: cohort, harness: "claude", cost: .reported(1.10))
        let two = execution("two", cohort: cohort, harness: "claude", cost: .reported(2.20))
        let silent = execution("silent", cohort: cohort, harness: "claude", cost: .unavailable)
        let native = execution("native", cohort: cohort, cost: .excluded)

        // when
        let result = costResult([one, two, silent, native], eligible: 3, available: 2)

        // then
        #expect(result.reportedCost.value == "$3.30")
        #expect(result.reportedCost.coverage == StatisticsProjection.partialReportedCoverage(reported: 2, eligible: 3))
        #expect(result.reportedCost.coverage == "From 2 of 3 executions; the rest are left out, not counted as zero")
    }

    @Test func givenPartialTinyOrZeroReportedCosts_whenProjected_thenSubCentAndZeroKeepPartialCoverage() {
        // given
        let tiny = execution("tiny", cohort: cohort, harness: "claude", cost: .reported(0.004))
        let zero = execution("zero", cohort: cohort, harness: "claude", cost: .reported(0))
        let silent = execution("silent", cohort: cohort, harness: "claude", cost: .unavailable)

        // when
        let tinyResult = costResult([tiny, silent], eligible: 2, available: 1)
        let zeroResult = costResult([zero, silent], eligible: 2, available: 1)

        // then
        #expect(tinyResult.reportedCost.value == "<$0.01")
        #expect(tinyResult.reportedCost.coverage == StatisticsProjection.partialReportedCoverage(reported: 1, eligible: 2))
        #expect(zeroResult.reportedCost.value == "$0.00")
        #expect(zeroResult.reportedCost.coverage == StatisticsProjection.partialReportedCoverage(reported: 1, eligible: 2))
    }

    @Test func givenPartialCostsUnderHarnessAndModelFilters_whenProjected_thenCoverageComesFromTheFilteredCohort() {
        // given
        let claudeOne = execution("c1", cohort: cohort, model: "opus", harness: "claude", cost: .reported(1))
        let claudeSilent = execution("c2", cohort: cohort, model: "opus", harness: "claude", cost: .unavailable)
        let claudeOther = execution("c3", cohort: cohort, model: "sonnet", harness: "claude", cost: .reported(100))
        let codex = execution("x1", cohort: cohort, model: "opus", harness: "codex", cost: .reported(50))
        let all = [claudeOne, claudeSilent, claudeOther, codex]
        let harness = StatisticsSelection(harness: StatisticsProjection.identity(
            "claude", namespace: "harness", unknown: StatisticsProjection.unknownHarness
        ))
        let model = StatisticsSelection(requestedModel: StatisticsProjection.identity(
            "opus", namespace: "model", unknown: StatisticsProjection.unknownModel
        ))

        // when
        let byHarness = costResult(all, eligible: 4, available: 3, selection: harness)
        let byModel = costResult(all, eligible: 4, available: 3, selection: model)

        // then
        #expect(byHarness.reportedCost.value == "$101.00")
        #expect(byHarness.reportedCost.coverage == StatisticsProjection.partialReportedCoverage(reported: 2, eligible: 3))
        #expect(byModel.reportedCost.value == "$51.00")
        #expect(byModel.reportedCost.coverage == StatisticsProjection.partialReportedCoverage(reported: 2, eligible: 3))
    }

    @Test func givenPartialCostsWithUnknownHarness_whenProjected_thenPerHarnessStaysUnavailableButOverviewCounts() {
        // given
        let reported = execution("reported", cohort: cohort, cost: .reported(3))
        let silent = execution("silent", cohort: cohort, cost: .unavailable)

        // when
        let result = costResult([reported, silent], eligible: 2, available: 1)

        // then
        #expect(result.reportedCost.value == "$3.00")
        #expect(result.reportedCost.coverage == StatisticsProjection.partialReportedCoverage(reported: 1, eligible: 2))
        #expect(result.perHarnessCosts[StatisticsProjection.unknownHarness] == StatisticsCostPresentation(
            value: "Unavailable", coverage: StatisticsProjection.reportedCoverage(reported: 1, eligible: 2)
        ))
    }

    @Test func givenUnqualifiedUnknownHarnessPartialSet_whenProjected_thenPerHarnessCostIsUntrusted() {
        // given
        let reported = execution("reported", cohort: cohort, cost: .reported(3))
        let silent = execution("silent", cohort: cohort, cost: .unavailable)

        // when
        let result = costResult([reported, silent], eligible: 2, available: 1, qualified: false)

        // then
        #expect(result.perHarnessCosts[StatisticsProjection.unknownHarness] == StatisticsCostPresentation())
    }

    @Test func givenNonFinitePartialSum_whenProjected_thenUnavailableWithPlainCoverage() {
        // given
        let big = execution("big", cohort: cohort, harness: "claude", cost: .reported(.greatestFiniteMagnitude))
        let bigger = execution("bigger", cohort: cohort, harness: "claude", cost: .reported(.greatestFiniteMagnitude))
        let silent = execution("silent", cohort: cohort, harness: "claude", cost: .unavailable)

        // when
        let result = costResult([big, bigger, silent], eligible: 3, available: 2)

        // then
        #expect(result.reportedCost.value == "Unavailable")
        #expect(result.reportedCost.coverage == "Reported by 2 of 3 executions")
    }

    @Test func givenNoReportedCosts_whenProjected_thenUnavailableWithZeroCoverage() {
        // given
        let silent = execution("silent", cohort: cohort, harness: "claude", cost: .unavailable)

        // when
        let result = costResult([silent], eligible: 1, available: 0)

        // then
        #expect(result.reportedCost.value == "Unavailable")
        #expect(result.reportedCost.coverage == "Reported by 0 of 1 executions")
    }

    @Test func givenUnqualifiedOrInvalidCosts_whenProjected_thenUnavailableAndTrustedCoverageOnly() {
        // given
        let reported = execution("reported", cohort: cohort, harness: "claude", cost: .reported(4.5))
        let silent = execution("silent", cohort: cohort, harness: "codex", cost: .unavailable)
        let invalid = execution("invalid", cohort: cohort, harness: "codex", cost: .invalid)

        // when
        let notQualified = costResult([reported, silent], eligible: 2, available: 1, qualified: false)
        let mixedInvalid = costResult([reported, silent, invalid], eligible: 3, available: 1)
        let mixedUnqualified = costResult(
            [reported, silent, execution("unq", cohort: cohort, harness: "codex", cost: .unqualified)], eligible: 3, available: 1
        )

        // then
        for result in [notQualified, mixedInvalid, mixedUnqualified] {
            #expect(result.reportedCost.value == "Unavailable")
            #expect(result.reportedCost.coverage == "Cost coverage unavailable")
        }
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
