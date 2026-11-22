import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

struct StatisticsTaskSummaryTests: StatisticsFixtures {

    // MARK: Counting

    @Test func givenInitialTask_whenSummarised_thenCountsOne() {
        // given
        let facts = [task("a")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "1")
        #expect(result.tasksDetail == "Last 30 days")
        #expect(result.successRate == "100%")
        #expect(result.successDetail == "0 failed")
        #expect(result.successCaption == "As of latest finished execution")
    }

    @Test func givenContinuationWithTrueChainRoot_whenSummarised_thenChainCountsOnce() {
        // given
        var root = task("a").raw; root["chain_root_task_id"] = .string("a")
        var next = task("b", continuation: "a").raw; next["chain_root_task_id"] = .string("a")

        // when
        let result = summary([fact(root), fact(next)])

        // then
        #expect(result.tasksRun == "1")
    }

    @Test func givenResumeInEngineShape_whenSummarised_thenChainCountsOnce() {
        // given
        var resumed = task("b", parent: "a").raw; resumed["chain_root_task_id"] = .string("b")

        // when
        let result = summary([task("a"), fact(resumed)])

        // then
        #expect(result.tasksRun == "1")
    }

    @Test func givenMixedInitialContinuationAndResume_whenSummarised_thenChainCountsOnce() {
        // given
        let facts = [task("a"), task("b", continuation: "a"), task("c", parent: "b")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "1")
    }

    @Test func givenIndependentTasks_whenSummarised_thenEachCounts() {
        // given
        let facts = [task("a"), task("b"), task("c")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "3")
    }

    @Test func givenWorkflowRootsAndMembers_whenSummarised_thenNoneCountAndRateIsUnavailable() {
        // given
        let facts = [workflow("run", cohort: start, wall: 60), task("member", root: "run")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "0")
        #expect(result.successRate == "Unavailable")
        #expect(result.successDetail == "No eligible finished tasks")
        #expect(result.successCaption.isEmpty)
        #expect(!result.coverage.contains("Agent-started tasks count as top-level tasks."))
        #expect(result.coverage.contains { $0.contains("Tasks still running without a finished execution aren't shown.") })
    }

    // MARK: Outcomes

    @Test func givenFailedRootWithCompletedResume_whenSummarised_thenOutcomeIsCompleted() {
        // given
        let facts = [task("a", status: "failed", started: start), task("b", parent: "a", started: start + 700)]

        // when
        let result = summary(facts)

        // then
        #expect(result.successRate == "100%")
        #expect(result.successDetail == "0 failed")
    }

    @Test func givenCompletedRootWithFailedContinuation_whenSummarised_thenOutcomeIsFailed() {
        // given
        let facts = [task("a"), task("b", continuation: "a", status: "failed", started: start + 700)]

        // when
        let result = summary(facts)

        // then
        #expect(result.successRate == "0%")
        #expect(result.successDetail == "1 failed")
    }

    @Test func givenTimedOutTask_whenSummarised_thenCountsAsFailed() {
        // given
        let facts = [task("a", status: "timed_out")]

        // when
        let result = summary(facts)

        // then
        #expect(result.successDetail == "1 failed")
    }

    @Test func givenCancelledTask_whenSummarised_thenCountsInDenominatorButNotAsFailed() {
        // given
        let facts = [task("a"), task("b", status: "cancelled")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "2")
        #expect(result.successRate == "50%")
        #expect(result.successDetail == "0 failed · 1 cancelled")
    }

    @Test func givenMixedOutcomes_whenSummarised_thenRoundsHalfUpAndNamesFailuresAndCancellations() {
        // given
        var facts = (0 ..< 7).map { task("ok\($0)") }
        facts += (0 ..< 2).map { task("bad\($0)", status: "failed") }
        facts.append(task("late", status: "timed_out"))
        facts.append(task("stop", status: "cancelled"))

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "11")
        #expect(result.successRate == "64%")
        #expect(result.successDetail == "3 failed · 1 cancelled")
    }

    @Test func givenNearlyAllOrNearlyNoneCompleted_whenSummarised_thenRateIsClamped() {
        // given
        let almost = (0 ..< 199).map { task("ok\($0)") } + [task("bad", status: "failed")]
        let barely = [task("ok")] + (0 ..< 199).map { task("bad\($0)", status: "failed") }

        // when
        let high = summary(almost)
        let low = summary(barely)

        // then
        #expect(high.successRate == "99%")
        #expect(low.successRate == "1%")
    }

    @Test func givenOneEighthCompleted_whenSummarised_thenHalfUpRoundsTo13() {
        // given
        let facts = [task("ok")] + (0 ..< 7).map { task("bad\($0)", status: "failed") }

        // when
        let result = summary(facts)

        // then
        #expect(result.successRate == "13%")
    }

    @Test func givenOneOfTwoHundredAndOneCompleted_whenSummarised_thenLowerClampShowsOnePercent() {
        // given
        let facts = [task("ok")] + (0 ..< 200).map { task("bad\($0)", status: "failed") }

        // when
        let result = summary(facts)

        // then
        #expect(result.successRate == "1%")
    }

    @Test func givenEqualFinishTimes_whenOutcomeChosen_thenStartThenFactIDBreakTheTie() {
        // given
        let early = task("a", status: "failed", started: start, duration: 1000)
        let later = task("b", parent: "a", started: start + 400, duration: 600)
        let sameStart = task("c", parent: "a", status: "failed", started: start + 400, duration: 600)

        // when
        let byStart = StatisticsProjection.chainOutcome([early, later])
        let byID = StatisticsProjection.chainOutcome([early, later, sameStart])
        let reversed = StatisticsProjection.chainOutcome([sameStart, later, early])

        // then
        #expect(byStart == .completed)
        #expect(byID == .failed)
        #expect(reversed == .failed)
    }

    // MARK: Period

    @Test func givenResumeWhoseParentIsAbsent_whenSummarised_thenNotCountedAndCoverageSaysSo() {
        // given
        let facts = [task("b", parent: "gone"), task("c", continuation: "gone")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "0")
        #expect(result.coverage.contains(
            "2 later executions aren't counted because their first run couldn't be identified in the available history."
        ))
    }

    @Test func givenRootPresentButMiddleMemberAbsent_whenSummarised_thenRootChainCountsAndLaterMembersAreReported() {
        // given
        let facts = [task("a"), task("c", parent: "b"), task("d", parent: "c")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "1")
        #expect(result.coverage.contains(
            "2 later executions aren't counted because their first run couldn't be identified in the available history."
        ))
    }

    @Test func givenRootAtSinceAndAtBefore_whenSummarised_thenSinceIsInAndBeforeIsOut() {
        // given
        let today = calendar.startOfDay(for: now)
        let since = calendar.date(byAdding: .day, value: -29, to: today)!.timeIntervalSince1970
        let before = calendar.date(byAdding: .day, value: 1, to: today)!.timeIntervalSince1970
        let facts = [task("in", started: since), task("out", started: before), task("early", started: since - 1)]

        // when
        let result = summary(facts, calendar: calendar)

        // then
        #expect(result.tasksRun == "1")
    }

    @Test func givenStaleAnchorAcrossMidnight_whenSummarised_thenSnapshotAnchorAndCalendarDecide() {
        // given: the snapshot calendar (Tokyo) differs from the derive calendar (Los Angeles)
        let formatter = ISO8601DateFormatter()
        let anchor = formatter.date(from: "2026-03-10T23:30:00+09:00")!
        let sameDay = formatter.date(from: "2026-03-10T23:40:00+09:00")!.timeIntervalSince1970
        let nextDay = formatter.date(from: "2026-03-11T00:10:00+09:00")!.timeIntervalSince1970
        let facts = [task("today", started: sameDay), task("tomorrow", started: nextDay)]

        // when
        let result = summary(facts, anchor: anchor, calendar: tokyo)

        // then
        #expect(result.tasksRun == "1")
    }

    @Test func givenLosAngelesSevenDayRangeAfterSpringForward_whenSummarised_thenSinceBoundIsLocalMidnightNotFixedSeconds() {
        // given: US DST began on 8 March 2026. Local midnight on 3 March is 08:00 UTC, while 6 x 86,400 s before
        // the local midnight of 9 March is 07:00 UTC, so the fixed-seconds bound sits one hour too early.
        let anchor = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))!
        let since = calendar.date(from: DateComponents(year: 2026, month: 3, day: 3))!.timeIntervalSince1970
        let fixedSecondsBound = calendar.startOfDay(for: anchor).timeIntervalSince1970 - 6 * day
        let facts = [
            task("atSince", started: since), task("secondBefore", started: since - 1),
            task("hourInGap", started: since - 1800), task("afterSince", started: since + 1)
        ]
        var selection = StatisticsSelection(); selection.range = .seven

        // when
        let result = summary(facts, selection: selection, anchor: anchor, calendar: calendar)

        // then
        #expect(fixedSecondsBound == since - 3600)
        #expect(since - 1800 >= fixedSecondsBound)
        #expect(result.tasksRun == "2")
    }

    @Test func givenSevenDayRange_whenSummarised_thenOnlyTheLastSevenDaysCount() {
        // given
        var selection = StatisticsSelection(); selection.range = .seven
        let facts = [task("recent"), task("old", started: now.timeIntervalSince1970 - 20 * day)]

        // when
        let seven = summary(facts, selection: selection)
        let thirty = summary(facts)

        // then
        #expect(seven.tasksRun == "1")
        #expect(seven.tasksDetail == "Last 7 days")
        #expect(thirty.tasksRun == "2")
    }

    // MARK: Filters

    @Test func givenFilters_whenSummarised_thenRootRepositoryHarnessAndModelDecide() {
        // given
        let facts = [
            task("a", repository: "/one", harness: "claude", model: "opus"),
            task("b", repository: "/two", harness: "codex", model: "gpt")
        ]
        var repository = StatisticsSelection(); repository.repository = StatisticsProjection.identity("/one", namespace: "repository", unknown: "")
        var harness = StatisticsSelection(); harness.harness = StatisticsProjection.identity("codex", namespace: "harness", unknown: "")
        var model = StatisticsSelection(); model.requestedModel = StatisticsProjection.identity("opus", namespace: "model", unknown: "")

        // when
        let byRepository = summary(facts, selection: repository)
        let byHarness = summary(facts, selection: harness)
        let byModel = summary(facts, selection: model)

        // then
        #expect(byRepository.tasksRun == "1")
        #expect(byHarness.tasksRun == "1")
        #expect(byModel.tasksRun == "1")
    }

    @Test func givenResumeWithDifferentHarness_whenFilteredByRootHarness_thenChainStaysWholeAndUsesEveryMember() {
        // given
        let facts = [
            task("a", status: "failed", harness: "claude"),
            task("b", parent: "a", started: start + 700, harness: "codex")
        ]
        var selection = StatisticsSelection()
        selection.harness = StatisticsProjection.identity("claude", namespace: "harness", unknown: "")

        // when
        let result = summary(facts, selection: selection)

        // then
        #expect(result.tasksRun == "1")
        #expect(result.successRate == "100%")
    }

    @Test func givenFilterOnMemberHarness_whenRootUsesAnotherHarness_thenChainIsNotCounted() {
        // given
        let facts = [task("a", harness: "claude"), task("b", parent: "a", started: start + 700, harness: "codex")]
        var selection = StatisticsSelection()
        selection.harness = StatisticsProjection.identity("codex", namespace: "harness", unknown: "")

        // when
        let result = summary(facts, selection: selection)

        // then
        #expect(result.tasksRun == "0")
    }

    @Test func givenRepositoryFilter_whenExcludedFactBelongsToAnotherRepository_thenItsCoverageLineIsAbsent() {
        // given
        let facts = [task("a", repository: "/one"), task("orphan", parent: "gone", repository: "/two")]
        var selection = StatisticsSelection()
        selection.repository = StatisticsProjection.identity("/one", namespace: "repository", unknown: "")

        // when
        let filtered = summary(facts, selection: selection)
        let unfiltered = summary(facts)

        // then
        #expect(!filtered.coverage.contains { $0.contains("first run couldn't be identified") })
        #expect(unfiltered.coverage.contains { $0.contains("first run couldn't be identified") })
    }

    // MARK: Integration

    @Test func givenFailedRootAndCompletedContinuationMergedFromTwoPages_whenDerived_thenOneChainAtOneHundredPercent() {
        // given: the history worker merges pages into one snapshot before projection
        let first = snapshot([task("a", status: "failed")])
        let second = snapshot([task("b", continuation: "a", started: start + 700)])
        let merged = snapshot(first.facts + second.facts)

        // when
        let result = StatisticsProjection.derive(snapshot: merged, selection: StatisticsSelection(), now: now, calendar: calendar)

        // then
        #expect(result.taskSummary?.tasksRun == "1")
        #expect(result.taskSummary?.successRate == "100%")
    }

    @Test func givenAllChainsExcludedWhileFinishedRecordsExist_whenSummarised_thenZeroUnavailableAndAccurateCoverage() {
        // given
        let facts = [task("b", parent: "gone"), task("c", kind: "future")]

        // when
        let result = summary(facts)

        // then
        #expect(result.tasksRun == "0")
        #expect(result.successRate == "Unavailable")
        #expect(result.successDetail == "No eligible finished tasks")
        #expect(result.coverage.count == 3)
    }

    @Test func givenCountAboveZero_whenSummarised_thenAgentStartedAndTerminalHistoryLinesShown() {
        // given / when
        let counted = summary([task("a")])
        let empty = StatisticsProjection.derive(snapshot: snapshot([]), selection: StatisticsSelection(), now: now, calendar: calendar)

        // then
        #expect(counted.coverage.first == "Agent-started tasks count as top-level tasks.")
        #expect(counted.coverage.contains {
            $0 == "Counts tasks with a finished execution and an identifiable first run in this period. "
                + "Tasks still running without a finished execution aren't shown."
        })
        #expect(empty.taskSummary == nil)
    }

    @Test func givenNodePage_whenDerived_thenSummaryIsHidden() {
        // given
        let workflowFact = workflow("run", cohort: start, wall: 60)
        let member = execution("m", cohort: start, root: "run")
        var selection = StatisticsSelection()
        let overview = StatisticsProjection.derive(
            snapshot: snapshot([workflowFact, member, task("a")]), selection: selection, now: now, calendar: calendar
        )
        selection.list = .workflows
        selection.nodes = overview.rows.first?.id

        // when
        let page = StatisticsProjection.derive(
            snapshot: snapshot([workflowFact, member, task("a")]), selection: selection, now: now, calendar: calendar
        )

        // then
        #expect(overview.taskSummary?.tasksRun == "1")
        #expect(page.nodes != nil)
        #expect(page.taskSummary == nil)
    }
}
