import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

struct StatisticsProjectionTests: StatisticsFixtures {
    @Test func givenRangeSelection_whenBoundsDerived_thenUsesLocalCalendarDaysAcrossDST() {
        // given
        let now = ISO8601DateFormatter().date(from: "2026-03-10T12:00:00-07:00")!

        // when
        let bounds = StatisticsProjection.bounds(range: .seven, now: now, calendar: calendar)

        // then
        let since = ISO8601DateFormatter().date(from: bounds.since)!
        let before = ISO8601DateFormatter().date(from: bounds.before)!
        #expect(calendar.component(.hour, from: since) == 0)
        #expect(calendar.dateComponents([.day], from: since, to: before).day == 7)
        #expect(before.timeIntervalSince(since) == 6 * 24 * 3600 + 23 * 3600)
    }

    @Test func givenSnapshotCrossesMidnight_whenDerivedAfterMidnight_thenTotalsAndBarsKeepOneAnchor() {
        // given
        let anchor = ISO8601DateFormatter().date(from: "2026-10-27T23:59:00-07:00")!
        let nextDay = ISO8601DateFormatter().date(from: "2026-10-28T00:00:30-07:00")!
        let firstIncludedDay = calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: anchor))!
        let root = workflow("root", cohort: firstIncludedDay.timeIntervalSince1970, wall: 300)

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([root], anchorDate: anchor, calendar: calendar),
            selection: StatisticsSelection(range: .seven), now: nextDay, calendar: calendar
        )

        // then
        #expect(result.chart.total == "5.0 min")
        #expect(result.chart.bars.count == 7)
        #expect(result.chart.bars.first?.workflowFraction ?? 0 > 0)
    }

    @Test func givenRange_whenDayBucketsBuild_thenLabelsStayReadableAndEveryDayRemains() {
        // given
        let now = ISO8601DateFormatter().date(from: "2026-10-28T12:00:00-07:00")!
        let cases: [(range: StatisticsRange, labelOffsets: [Int])] = [
            (.seven, Array(0 ... 6)),
            (.thirty, [0, 7, 14, 21, 29]),
            (.ninety, [0, 22, 44, 66, 89])
        ]

        for testCase in cases {
            // when
            let buckets = StatisticsProjection.dayBuckets(
                workflows: [], standalone: [], selection: StatisticsSelection(range: testCase.range),
                now: now, calendar: calendar
            )

            // then
            let expectedStart = calendar.date(
                byAdding: .day, value: 1 - testCase.range.rawValue, to: calendar.startOfDay(for: now)
            )!
            let expectedDates = (0 ..< testCase.range.rawValue).map { offset -> String in
                let day = calendar.date(byAdding: .day, value: offset, to: expectedStart)!
                let formatter = DateFormatter()
                formatter.calendar = calendar
                formatter.timeZone = calendar.timeZone
                formatter.dateFormat = "MMM d"
                return formatter.string(from: day)
            }
            #expect(buckets.count == testCase.range.rawValue)
            #expect(buckets.map(\.id) == (0 ..< testCase.range.rawValue).map(String.init))
            #expect(buckets.map(\.date) == expectedDates)
            #expect(buckets.indices.filter { !buckets[$0].label.isEmpty } == testCase.labelOffsets)
        }
    }

    @Test func givenRequestedCalendar_whenMetadataFormatsStart_thenItUsesThatTimezone() {
        // given
        let instant = ISO8601DateFormatter().date(from: "2026-03-10T01:00:00Z")!
        let execution = execution("timezone", cohort: instant.timeIntervalSince1970)
        let expectedFormatter = DateFormatter()
        expectedFormatter.calendar = calendar
        expectedFormatter.timeZone = calendar.timeZone
        expectedFormatter.dateStyle = .medium
        expectedFormatter.timeStyle = .short

        // when
        let result = StatisticsProjection.metadata(execution, calendar: calendar)

        // then
        #expect(result.contains(expectedFormatter.string(from: instant)))
    }

    @Test func givenRootAndDescendantsAcrossRangeBoundary_whenProjected_thenRootWallAndChildrenShareRootCohort() {
        // given
        let now = ISO8601DateFormatter().date(from: "2026-10-27T12:00:00-07:00")!
        let rootCohort = now.timeIntervalSince1970 - 2 * 86400
        let root = workflow("root", cohort: rootCohort, wall: 900)
        var childRaw = execution("child", cohort: now.timeIntervalSince1970 - 100 * 86400, duration: 120, root: "root").raw
        childRaw["cohort_started_at"] = .number(rootCohort)
        let child = fact(childRaw)
        let standalone = execution("standalone", cohort: now.timeIntervalSince1970 - 2 * 86400, duration: 30)
        let selection = StatisticsSelection(range: .seven)

        // when
        let result = StatisticsProjection.derive(snapshot: snapshot([root, child, standalone]), selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.chart.workflowTotal == "15.0 min")
        #expect(result.chart.taskTotal == "30 s")
        #expect(result.chart.bars.last?.workflowFraction == 0)
        #expect(result.chart.bars.suffix(7).contains { $0.taskFraction > 0 })
    }

    @Test func givenModelFilter_whenProjected_thenChartUsesMatchingExecutionTimeAndExactRepository() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = workflow("root", cohort: now.timeIntervalSince1970, wall: 900)
        let matching = execution("retry", cohort: now.timeIntervalSince1970, duration: 75, root: "root", model: "requested")
        let other = execution("resume", cohort: now.timeIntervalSince1970, duration: 25, root: "root", repository: "/repo-copy", model: "other")
        var selection = StatisticsSelection(repository: StatisticsProjection.repositoryID(root), requestedModel: "model:\"requested\"")

        // when
        let source = snapshot([root, matching, other])
        let grouped = StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)
        selection.nodes = grouped.rows.first?.id
        let result = StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.chart.title == "Execution time")
        #expect(result.chart.workflowTotal == "1.2 min")
        #expect(result.nodes?.executionTime == "1.2 min")
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.value == "1.2 min")
    }

    @Test func givenRepositoryFilterOnWorkflow_whenDescendantUsesAnotherRepository_thenRootCohortRetainsDescendant() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = workflow("root", cohort: now.timeIntervalSince1970, wall: 120, repo: "/repo")
        var descendantRaw = execution("child", cohort: now.timeIntervalSince1970, duration: 45, root: "root", repository: "/child-repo").raw
        descendantRaw["node_id"] = .string("build")
        let source = snapshot([root, fact(descendantRaw)])
        var selection = StatisticsSelection(repository: StatisticsProjection.repositoryID(root))
        let initial = StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)
        selection.nodes = initial.rows.first?.id

        // when
        let result = StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.nodes?.executionTime == "45 s")
        #expect(result.nodes?.rows.first?.title == "build")
    }

    @Test func givenSeparateInitialRetryAndResumeFacts_whenRanked_thenEachTerminalExecutionIsCounted() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let initial = execution("initial", cohort: now.timeIntervalSince1970, duration: 10)
        let retry = execution("retry", cohort: now.timeIntervalSince1970, duration: 20)
        let resume = execution("resume", cohort: now.timeIntervalSince1970, duration: 30)
        let selection = StatisticsSelection(list: .tasks)

        // when
        let result = StatisticsProjection.derive(snapshot: snapshot([initial, retry, resume]), selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.value == "1.0 min")
    }

    @Test func givenMissingAndCollidingRequestedModels_whenOptionsBuilt_thenUnknownIsDistinctFromLiteralAndEffectiveModelIgnored() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = execution("a", cohort: now.timeIntervalSince1970, model: nil, harness: nil)
        let second = execution("b", cohort: now.timeIntervalSince1970, model: "Unknown", harness: "vibe")
        var thirdRaw = second.raw; thirdRaw["id"] = .string("c"); thirdRaw["requested_model"] = .string("unknown:requested-model")
        thirdRaw["effective_model"] = .string("ignored")

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([first, second, fact(thirdRaw)]), selection: StatisticsSelection(), now: now, calendar: calendar
        )

        // then
        #expect(result.modelOptions.count == 3)
        #expect(result.modelOptions.map(\.label).contains("Unknown"))
        #expect(result.modelOptions.map(\.label).contains("unknown:requested-model"))
        #expect(!result.modelOptions.map(\.label).contains("ignored"))
        #expect(result.harnessOptions.contains { $0.label == "Unknown" })
        #expect(result.harnessOptions.contains { $0.label == "vibe" })
    }

    @Test func givenDurationWithoutUsageAndWaitQualification_whenFiltered_thenDurationSurvivesAndDisclosureIsExplicit() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let execution = execution("e", cohort: now.timeIntervalSince1970, duration: 42, model: "requested", timeQualification: "unknown")
        let selection = StatisticsSelection(measure: .time, requestedModel: "model:\"requested\"")

        // when
        let result = StatisticsProjection.derive(snapshot: snapshot([execution]), selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.chart.title == "Execution time")
        #expect(result.chart.total == "42 s")
        #expect(result.coverage.contains { $0.contains("user waits may be included") })
        #expect(result.coverage.contains { $0.contains("Unknown is not an observed or effective model") })
    }

    @Test func givenUnavailableTokensAndQualifiedDuration_whenUsageSelected_thenTokenTotalIsUnavailable() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let execution = execution("e", cohort: now.timeIntervalSince1970, duration: 42)
        let selection = StatisticsSelection(measure: .usage)

        // when
        let result = StatisticsProjection.derive(snapshot: snapshot([execution]), selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.chart.total == "Unavailable")
        #expect(result.chart.title == "Usage")
        #expect(result.chart.bars.count == 30)
    }

    @Test func givenKnownAndMissingUsage_whenUsageSelected_thenKnownSubtotalAndMissingCoverageRemainVisible() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let known = execution("known", cohort: now.timeIntervalSince1970, usage: 100)
        let missing = execution("missing", cohort: now.timeIntervalSince1970 + 1)

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([known, missing], eligible: 2, available: 1),
            selection: StatisticsSelection(measure: .usage), now: now, calendar: calendar
        )

        // then
        #expect(result.chart.taskTotal == "100 tokens")
        #expect(result.chart.total == "100 tokens")
        #expect(result.coverage.contains { $0.contains("1 of 2") })
        #expect(result.coverage.contains { $0.contains("Partial") })
    }

    @Test func givenUsageWithUnqualifiedResumeScope_whenCategoriesBuilt_thenUnknownCategoriesAreNotSummed() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var raw = execution("resume", cohort: now.timeIntervalSince1970, usage: 25).raw
        var accounting = raw["accounting"]!.objectValue!
        accounting["scope"] = .string("conversation")
        raw["accounting"] = .object(accounting)

        // when
        let result = StatisticsProjection.derive(snapshot: snapshot([fact(raw)]), selection: StatisticsSelection(), now: now, calendar: calendar)

        // then
        #expect(result.coverage.contains { $0.contains("input: unavailable") })
    }

    @Test func givenNativeLogicalOwnerAndExecution_whenProjected_thenLogicalRowsRemainWithoutDoubleAdding() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let owner = execution("owner", cohort: now.timeIntervalSince1970, duration: 60, usage: 100)
        var nativeRaw = execution("native-copy", cohort: now.timeIntervalSince1970, duration: 60, usage: 100, durationAdditive: false).raw
        nativeRaw["chain_root_task_id"] = .string("task-root")
        var nativeAccounting = nativeRaw["accounting"]!.objectValue!
        nativeAccounting["contribution_id"] = owner.accounting["contribution_id"]
        nativeRaw["accounting"] = .object(nativeAccounting)

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([owner, fact(nativeRaw)], eligible: 1, available: 1),
            selection: StatisticsSelection(measure: .usage, list: .tasks), now: now, calendar: calendar
        )

        // then
        #expect(result.chart.taskTotal == "100 tokens")
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.children.count == 2)
        #expect(result.coverage.contains { $0.contains("native logical records reference owner contributions") })
    }

    @Test func givenModelFilter_whenCoverageBuilt_thenAvailabilityCountsOnlySelectedExecutions() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let selected = execution("selected", cohort: now.timeIntervalSince1970, model: "wanted", usage: 100)
        let excluded = execution("excluded", cohort: now.timeIntervalSince1970, model: "other")

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([selected, excluded], eligible: 2, available: 1),
            selection: StatisticsSelection(requestedModel: "model:\"wanted\""), now: now, calendar: calendar
        )

        // then
        #expect(result.coverage.contains { $0.contains("1 of 1") })
    }

    @Test func givenTasksListWithUnqualifiedWorkflowAndQualifiedTask_whenProjected_thenChartAndRankingCoverageStayDistinct() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = workflow("root", cohort: now.timeIntervalSince1970, wall: 120)
        let workflowExecution = execution(
            "workflow-execution", cohort: now.timeIntervalSince1970, duration: 90,
            root: "root", timeQualification: "elapsed_only"
        )
        let standalone = execution("standalone", cohort: now.timeIntervalSince1970, duration: 30, usage: 100)

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([root, workflowExecution, standalone], eligible: 2, available: 1),
            selection: StatisticsSelection(list: .tasks), now: now, calendar: calendar
        )

        // then
        #expect(result.coverage.contains { $0.contains("Chart accounting: Partial · 1 of 2 independent executions") })
        #expect(result.coverage.contains { $0.contains("Tasks ranking accounting: Complete · 1 of 1 independent executions") })
        #expect(result.coverage.contains { $0.contains("user waits may be included") })
    }

    @Test(arguments: ["completed", "failed", "cancelled", "timed_out"])
    func givenFinishedExecutionOutcome_whenProjected_thenItContributesExactlyOnce(status: String) {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let finished = execution("finished", cohort: now.timeIntervalSince1970, duration: 60, status: status)
        let selection = StatisticsSelection(list: .tasks)

        // when
        let result = StatisticsProjection.derive(snapshot: snapshot([finished]), selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.value == "1.0 min")
        #expect(result.rows.first?.subtitle.contains("1 execution records") == true)
        if status == "timed_out" {
            #expect(result.rows.first?.children.first?.subtitle.contains("failed (timed out)") == true)
        }
    }

    @Test func givenSameWorkflowAcrossRepositoriesAndRevisions_whenGrouped_thenOneWorkflowRowRetainsAllRuns() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = workflow("one", cohort: now.timeIntervalSince1970, wall: 60, repo: "/repo-a")
        var secondRaw = workflow("two", cohort: now.timeIntervalSince1970, wall: 120, repo: "/repo-b").raw
        secondRaw["workflow_revision"] = .number(2)

        // when
        let result = StatisticsProjection.derive(snapshot: snapshot([first, fact(secondRaw)]), selection: StatisticsSelection(), now: now, calendar: calendar)

        // then
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.value == "3.0 min")
    }

    @Test func givenMissingRepository_whenOptionsBuilt_thenUnknownCanBeSelected() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var raw = workflow("run", cohort: now.timeIntervalSince1970, wall: 30).raw
        raw.removeValue(forKey: "repo_path")

        // when
        let available = StatisticsProjection.derive(snapshot: snapshot([fact(raw)]), selection: StatisticsSelection(), now: now, calendar: calendar)
        let unknown = available.repositoryOptions.first { $0.label == "Unknown" }
        let result = StatisticsProjection.derive(
            snapshot: snapshot([fact(raw)]), selection: StatisticsSelection(repository: unknown?.id), now: now, calendar: calendar
        )

        // then
        #expect(unknown != nil)
        #expect(result.rows.count == 1)
    }

    @Test func givenEmptyRepositoryPath_whenOptionsBuilt_thenItUsesUnknownIdentityAndLabel() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let emptyRepository = workflow("empty-repo", cohort: now.timeIntervalSince1970, wall: 30, repo: "")

        // when
        let available = StatisticsProjection.derive(
            snapshot: snapshot([emptyRepository]), selection: StatisticsSelection(), now: now, calendar: calendar
        )
        let unknown = available.repositoryOptions.first { $0.label == "Unknown" }
        let result = StatisticsProjection.derive(
            snapshot: snapshot([emptyRepository]),
            selection: StatisticsSelection(repository: unknown?.id), now: now, calendar: calendar
        )

        // then
        #expect(unknown?.id == StatisticsProjection.unknownRepository)
        #expect(result.rows.count == 1)
    }

    @Test func givenRetainedFiltersAbsentFromCurrentOptions_whenProjected_thenLabelsRemainReadable() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let selection = StatisticsSelection(
            repository: "repository:\"/removed\"", harness: "harness:\"claude\"", requestedModel: "model:\"old-model\""
        )

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([]), selection: selection, now: now, calendar: calendar
        )

        // then
        #expect(result.repositoryLabel == "/removed")
        #expect(result.harnessLabel == "claude")
        #expect(result.modelLabel == "old-model")
    }

    @Test func givenWorkflowAndExecutionUsage_whenExpanded_thenChildShowsTimeAndUsageMetadata() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = workflow("root", cohort: now.timeIntervalSince1970, wall: 120)
        var nodeRaw = execution("node", cohort: now.timeIntervalSince1970, duration: 60, root: "root", usage: 80).raw
        nodeRaw["title"] = .string("Build")

        // when
        let result = StatisticsProjection.derive(snapshot: snapshot([root, fact(nodeRaw)]), selection: StatisticsSelection(), now: now, calendar: calendar)

        // then
        #expect(result.rows.first?.children.first?.value == "2.0 min")
        #expect(result.rows.first?.children.first?.secondaryValue.contains("80 tokens") == true)
    }

    @Test func givenNodeExecutions_whenNodePageBuilt_thenRowsHaveComparableSharesAndSecondaryValues() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let root = workflow("root", cohort: now.timeIntervalSince1970, wall: 120)
        var firstRaw = execution("first", cohort: now.timeIntervalSince1970, duration: 30, root: "root", usage: 50).raw
        firstRaw["node_id"] = .string("build")
        var secondRaw = execution("second", cohort: now.timeIntervalSince1970, duration: 90, root: "root", usage: 150).raw
        secondRaw["node_id"] = .string("test")
        let source = snapshot([root, fact(firstRaw), fact(secondRaw)])
        var selection = StatisticsSelection(measure: .time)
        let initial = StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)
        selection.nodes = initial.rows.first?.id

        // when
        let result = StatisticsProjection.derive(snapshot: source, selection: selection, now: now, calendar: calendar)

        // then
        #expect(result.nodes?.rows.count == 2)
        #expect(result.nodes?.rows.contains { $0.fraction > 0 } == true)
        #expect(result.nodes?.rows.contains { !$0.secondaryValue.isEmpty } == true)
    }

    @Test func givenEightHundredEightyMinutesAndSevenDays_whenChartBuilt_thenLabelsStayOrderedAndDurationDoesNotOverflow() {
        // given
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let longRun = workflow("long", cohort: now.timeIntervalSince1970, wall: 880 * 60)

        // when
        let result = StatisticsProjection.derive(
            snapshot: snapshot([longRun]), selection: StatisticsSelection(range: .seven), now: now, calendar: calendar
        )

        // then
        #expect(result.chart.workflowTotal == "14.7 h")
        #expect(result.chart.bars.map(\.id) == (0 ..< 7).map(String.init))
        #expect(result.chart.bars.count == 7)
    }
}
