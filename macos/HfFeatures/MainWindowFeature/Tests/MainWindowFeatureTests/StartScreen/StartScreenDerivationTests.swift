import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - StartScreenDerivationTests

@Suite struct StartScreenDerivationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 27, _ hour: Int = 14, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func task(_ id: String, status: String, finished: Date? = nil, owner: JSONValue? = .null,
                      extra: [String: JSONValue] = [:]) -> TaskInfo {
        var raw: [String: JSONValue] = ["task_id": .string(id), "status": .string(status)]
        if let owner { raw["workflow_run_id"] = owner }
        if let finished { raw["finished_at"] = .string(iso(finished)) }
        raw.merge(extra) { _, new in new }
        return TaskInfo(.object(raw))!
    }

    private func run(_ id: String, status: String, finished: Date? = nil, settling: Bool = false,
                     parent: String? = nil, kind: String = "workflow", created: Date? = nil,
                     updated: Date? = nil) -> [String: JSONValue] {
        var value: [String: JSONValue] = [
            "workflow_id": .string(id), "status": .string(status), "kind": .string(kind), "settling": .bool(settling)
        ]
        if let parent { value["parent_workflow_run_id"] = .string(parent) }
        if let finished { value["finished_at"] = .number(finished.timeIntervalSince1970) }
        if let created { value["created_at"] = .number(created.timeIntervalSince1970) }
        if let updated { value["updated_at"] = .number(updated.timeIntervalSince1970) }
        return value
    }

    private func definition(_ name: String, id: String? = nil) -> WorkflowRecord {
        WorkflowRecord(raw: ["name": .string(name), "workflow_id": .string(id ?? name)])
    }

    private func derive(
        tasks: [TaskInfo]? = [], runs: [[String: JSONValue]]? = [], definitions: [WorkflowRecord] = [], now: Date? = nil
    ) -> StartScreenPresentation {
        StartScreenDerivation.make(snapshot: StartScreenSnapshot(tasks: tasks, runs: runs, definitions: definitions),
                                   now: now ?? date(), calendar: calendar)
    }

    @Test(arguments: [
        (0, "Working late"), (4, "Working late"), (5, "Early start"), (6, "Early start"), (7, "Good morning"),
        (11, "Good morning"), (12, "Good afternoon"), (17, "Good afternoon"), (18, "Good evening"),
        (22, "Good evening"), (23, "Working late")
    ])
    func givenLocalHour_whenGreetingIsDerived_thenUsesTheApprovedBoundary(_ hour: Int, _ expected: String) {
        // given / when
        let greeting = StartScreenDerivation.greeting(hour: hour)

        // then
        #expect(greeting == expected)
    }

    @Test func givenRunningTasksAndWorkflowRuns_whenDerived_thenCountsExactRunningAndExcludesBuildersChildrenAndSettling() {
        // given
        let tasks = [task("t1", status: "running"), task("t2", status: "starting"),
                     task("nested", status: "running", owner: .string("run"))]
        let runs = [run("wf", status: "running"), run("builder", status: "running", kind: "builder"),
                    run("child", status: "running", parent: "root"), run("settling", status: "running", settling: true)]

        // when
        let result = derive(tasks: tasks, runs: runs)

        // then
        #expect(result.status == "1 task and 1 workflow running.")
    }

    @Test func givenNonRunningTaskAndWorkflowStates_whenDerived_thenDoesNotCountThemAsRunning() {
        // given
        let inactive = ["starting", "paused", "needs_input", "cancelling", "settling"]
        let tasks = inactive.enumerated().map { task("task-\($0.offset)", status: $0.element) }
        let runs = inactive.map { run("workflow-\($0)", status: $0) }

        // when
        let result = derive(tasks: tasks, runs: runs)

        // then
        #expect(result.status == "Nothing running.")
    }

    @Test func givenTaskAndWorkflowCompletionsAtDifferentWindows_whenDerived_thenUsesTodayPrecedenceAndPluralizes() {
        // given
        let today = date(2026, 10, 27, 9)
        let yesterday = date(2026, 10, 26, 23)
        let result = derive(tasks: [task("today-a", status: "completed", finished: today), task("today-b", status: "failed", finished: today)],
                            runs: [run("wf", status: "cancelled", finished: today), run("old", status: "completed", finished: yesterday)], now: date())

        // then
        #expect(result.status == "Nothing running. 2 tasks and 1 workflow finished today.")
    }

    @Test func givenNoActivity_whenDerived_thenReportsNothingRunningAndOmitsFinishedClause() {
        // given / when
        let result = derive()

        // then
        #expect(result.status == "Nothing running.")
    }

    @Test func givenSevenDayCompletionAndOlderCompletion_whenDerived_thenUsesOnlyTheInclusiveSevenDayWindow() {
        // given
        let now = date(2026, 10, 27, 14)
        let sevenDaysAgo = date(2026, 10, 20, 14)
        let outside = date(2026, 10, 20, 13, 59)

        // when
        let result = derive(tasks: [task("inside", status: "cancelled", finished: sevenDaysAgo),
                                    task("outside", status: "failed", finished: outside)], now: now)

        // then
        #expect(result.status == "Nothing running. 1 task finished in the last 7 days.")
    }

    @Test func givenDaylightSavingBoundary_whenDerived_thenUsesCalendarDaysInsteadOfFixedTwentyFourHours() {
        // given
        var eastern = Calendar(identifier: .gregorian)
        eastern.timeZone = TimeZone(identifier: "America/New_York")!
        let now = eastern.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 15))!
        let yesterday = eastern.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 45))!
        let localNow = StartScreenDerivation.make(snapshot: StartScreenSnapshot(
            tasks: [task("dst", status: "completed", finished: yesterday)], runs: [], definitions: []), now: now, calendar: eastern)

        // then
        #expect(now.timeIntervalSince(yesterday) < 24 * 60 * 60)
        #expect(localNow.status == "Nothing running. 1 task finished yesterday.")
    }

    @Test func givenTaskOwnershipOrCompletionEvidenceIsMissing_whenDerived_thenOmitsStatusInsteadOfAssumingZero() {
        // given
        let missingOwner = task("legacy", status: "completed", finished: date(), owner: nil)
        let missingFinish = task("unknown", status: "completed")

        // when / then
        #expect(derive(tasks: [missingOwner]).status == nil)
        #expect(derive(tasks: [missingFinish]).status == nil)
    }

    @Test func givenTerminalWorkflowFinishesRecentlyWithoutTimestamp_whenDerived_thenOmitsStatus() {
        // given
        let recentUnknown = run("wf", status: "failed", updated: date())

        // when / then
        #expect(derive(runs: [recentUnknown]).status == nil)
    }

    @Test(arguments: [
        ["workflow_id": JSONValue.string("wf"), "kind": .string("workflow"), "settling": .bool(false)],
        ["workflow_id": JSONValue.string("wf"), "status": .string("running"), "settling": .bool(false)],
        ["workflow_id": JSONValue.string("wf"), "kind": .string("workflow"), "status": .string("running")]
    ])
    func givenWorkflowClassificationOrSettlingEvidenceIsMissing_whenDerived_thenOmitsStatus(_ run: [String: JSONValue]) {
        // given / when
        let result = derive(runs: [run])

        // then
        #expect(result.status == nil)
    }

    @Test func givenTerminalWorkflowWasUpdatedBeforeSevenDayWindow_whenDerived_thenDoesNotUseUpdateAsCompletionTime() {
        // given
        let oldUnknown = run("wf", status: "failed", created: date(2026, 10, 18, 13), updated: date(2026, 10, 19, 13))

        // when
        let result = derive(runs: [oldUnknown])

        // then
        #expect(result.status == "Nothing running.")
    }

    @Test func givenLegacyCompletionHasNoSafeAgeBound_whenDerived_thenKeepsHistoryUnknown() {
        // given
        let scenarios: [(Date?, Date)] = [
            (nil, date(2026, 10, 19, 13)),
            (date(2026, 10, 20, 14), date(2026, 10, 19, 13)),
            (date(2026, 10, 18, 13), date(2026, 10, 28, 13))
        ]

        // when / then
        for (created, updated) in scenarios {
            let legacy = run("wf", status: "failed", created: created, updated: updated)
            #expect(derive(runs: [legacy]).status == nil)
        }
    }

    @Test func givenFutureFinishesAndLocalCalendarBoundary_whenDerived_thenExcludesFutureAndUsesYesterdayOnlyIfNoTodayCompletion() {
        // given
        let now = date(2026, 10, 27, 0, 15)
        let previousLocalDay = date(2026, 10, 26, 23, 59)
        let future = date(2026, 10, 27, 0, 16)

        // when
        let result = derive(tasks: [task("yesterday", status: "completed", finished: previousLocalDay),
                                    task("future", status: "completed", finished: future)], now: now)

        // then
        #expect(result.status == "Nothing running. 1 task finished yesterday.")
    }

    @Test func givenHistoryIsUnavailable_whenDerived_thenKeepsDefinitionsAlphabeticalAndHidesCounts() {
        // given
        let definitions = [definition("Zebra"), definition("Alpha")]

        // when
        let result = derive(tasks: nil, runs: nil, definitions: definitions)

        // then
        #expect(result.status == nil)
        #expect(result.rows.map(\.name) == ["Alpha", "Zebra"])
        #expect(result.rows.allSatisfy { $0.count == nil })
    }

    @Test func givenKnownRuns_whenDerived_thenRanksByPinnedIdentityWithAlphabeticalTiesAndShowsAtMostThree() {
        // given
        let definitions = [definition("Delta", id: "d"), definition("Charlie", id: "c"), definition("Bravo", id: "b"),
                           definition("Alpha", id: "a")]
        let runs = [run("a", status: "failed", finished: date()), run("c", status: "running"),
                    run("c", status: "cancelled", finished: date())]

        // when
        let result = derive(runs: runs, definitions: definitions)

        // then
        #expect(result.rows.map(\.name) == ["Charlie", "Alpha", "Bravo"])
        #expect(result.rows.map(\.count) == ["2 runs", "1 run", "Never run"])
        #expect(result.total == 4)
    }

    @Test func givenRunWithoutPinnedIdentity_whenDerived_thenDoesNotRankByWorkflowName() {
        // given
        let legacy = run("", status: "running")

        // when
        let result = derive(runs: [legacy], definitions: [definition("Saved", id: "saved")])

        // then
        #expect(result.rows.map(\.name) == ["Saved"])
        #expect(result.rows[0].count == nil)
    }

    @Test func givenPresentButEmptyParentRunId_whenDerived_thenTreatsTheRunAsUnclassified() {
        // given
        let runWithEmptyParent = run("wf", status: "running", parent: "")

        // when
        let result = derive(runs: [runWithEmptyParent], definitions: [definition("Workflow", id: "wf")])

        // then
        #expect(result.status == nil)
        #expect(result.rows[0].count == nil)
    }

    @Test func givenTaskFinishedExactlyAtLocalMidnight_whenDerived_thenCountsItInToday() {
        // given
        let midnight = date(2026, 10, 27, 0)

        // when
        let result = derive(tasks: [task("midnight", status: "timed_out", finished: midnight)], now: date(2026, 10, 27, 0, 1))

        // then
        #expect(result.status == "Nothing running. 1 task finished today.")
    }
}
