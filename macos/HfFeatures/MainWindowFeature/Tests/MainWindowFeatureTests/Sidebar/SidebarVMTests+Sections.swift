//
//  SidebarVMTests+Sections.swift
//  MainWindowFeatureTests
//
//  Settled plan D10/Phase 4: whole-tree and group bucketing into Running / Today / Earlier, ordering,
//  and the filter menu staying available with zero results. Also hosts the test-only accessors the
//  older Tree/Conversation suites read rows through.
//

import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - Test accessors

extension SidebarVM {

    func items(in bucket: SidebarSection.Bucket) -> [SidebarItem] {
        sections.first { $0.bucket == bucket }?.items ?? []
    }

    func rows(in bucket: SidebarSection.Bucket) -> [TaskRowModel] {
        items(in: bucket).compactMap { if case .task(let row) = $0 { row } else { nil } }
    }

    func groups(in bucket: SidebarSection.Bucket) -> [ParallelGroup] {
        items(in: bucket).compactMap { if case .group(let group) = $0 { group.group } else { nil } }
    }

    var runningRows: [TaskRowModel] { rows(in: .running) }
    /// Today's rows, then Earlier's.
    var recentRows: [TaskRowModel] { rows(in: .today) + rows(in: .earlier) }
    var parallelGroups: [ParallelGroup] { SidebarSection.Bucket.allCases.flatMap { groups(in: $0) } }
}

@MainActor
extension SidebarVMTests {

    // MARK: - Bucketing (D10)

    /// Noon on a fixed day, so "today"/"earlier" never depend on when the suite runs.
    private var noon: Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12))!
    }

    private func makeBucketSUT() -> SUT {
        let harness = makeSUT()
        let clock = noon
        harness.sut.currentDate = { clock }
        return harness
    }

    @Test func givenRunningTodayAndEarlierRoots_whenListed_thenEachLandsInItsBucketInOrder() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        harness.tasksSubject.send([
            task(id: "run", status: "running", startedAt: noon.addingTimeInterval(-600)),
            task(id: "today", status: "completed", startedAt: noon.addingTimeInterval(-3600)),
            task(id: "old", status: "completed", startedAt: noon.addingTimeInterval(-3 * 86_400))
        ])

        // then
        await waitUntil { sut.sections.count == 3 }
        await sut.waitForPresentation()
        #expect(sut.sections.map(\.bucket) == [.running, .today, .earlier])
        #expect(sut.runningRows.map(\.id) == ["run"])
        #expect(sut.rows(in: .today).map(\.id) == ["today"])
        #expect(sut.rows(in: .earlier).map(\.id) == ["old"])
    }

    @Test func givenAFinishedRootWithARunningChild_whenListed_thenTheWholeTreeIsInRunning() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        harness.tasksSubject.send([
            task(id: "root", status: "completed", startedAt: noon.addingTimeInterval(-3 * 86_400)),
            task(id: "child", status: "running", startedAt: noon.addingTimeInterval(-60), spawnedBy: "root")
        ])

        // then — the root stays Running even though it is old and finished; nothing is split off.
        await waitUntil { !sut.sections.isEmpty }
        await sut.waitForPresentation()
        #expect(sut.sections.map(\.bucket) == [.running])
        #expect(sut.runningRows.map(\.id) == ["root", "child"])
    }

    @Test func givenASettledTreeStartedYesterday_whenListed_thenItsDescendantsStayWithItInEarlier() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()

        // when — the child started today, but bucketing follows the root's start.
        harness.tasksSubject.send([
            task(id: "root", status: "completed", startedAt: noon.addingTimeInterval(-2 * 86_400)),
            task(id: "child", status: "completed", startedAt: noon.addingTimeInterval(-60), spawnedBy: "root")
        ])

        // then
        await waitUntil { !sut.sections.isEmpty }
        await sut.waitForPresentation()
        #expect(sut.sections.map(\.bucket) == [.earlier])
        #expect(sut.rows(in: .earlier).map(\.id) == ["root", "child"])
    }

    @Test func givenParallelGroups_whenListed_thenTheyBucketByRunningThenLatestMemberStart() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        harness.tasksSubject.send([
            task(id: "a1", status: "running", startedAt: noon.addingTimeInterval(-120), group: "live"),
            task(id: "a2", status: "completed", startedAt: noon.addingTimeInterval(-300), group: "live"),
            task(id: "b1", status: "completed", startedAt: noon.addingTimeInterval(-7200), group: "today-run"),
            task(id: "b2", status: "completed", startedAt: noon.addingTimeInterval(-3600), group: "today-run"),
            task(id: "c1", status: "completed", startedAt: noon.addingTimeInterval(-5 * 86_400), group: "old-run"),
            task(id: "c2", status: "completed", startedAt: noon.addingTimeInterval(-4 * 86_400), group: "old-run")
        ])

        // then
        await waitUntil { sut.parallelGroups.count == 3 }
        #expect(sut.groups(in: .running).map(\.name) == ["live"])
        #expect(sut.groups(in: .today).map(\.name) == ["today-run"])
        #expect(sut.groups(in: .earlier).map(\.name) == ["old-run"])
        #expect(sut.runningRows.isEmpty)
    }

    @Test func givenYesterdayGroupRunAgainToday_whenNewestRunStops_thenGroupStaysFirstInToday() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()
        defer { sut.didDisappear() }
        let old = task(id: "old-run", status: "completed", startedAt: noon.addingTimeInterval(-86400), group: "repeat")
        let other = task(id: "other", status: "completed", startedAt: noon.addingTimeInterval(-3600))
        harness.tasksSubject.send([old, other, task(id: "rerun", status: "running", startedAt: noon.addingTimeInterval(-60), group: "repeat")])
        await waitUntil { sut.groups(in: .running).count == 1 }
        // when
        harness.tasksSubject.send([old, other, task(id: "rerun", status: "completed", startedAt: noon.addingTimeInterval(-60), group: "repeat")])
        // then
        await waitUntil { sut.items(in: .running).isEmpty && sut.items(in: .today).count == 2 }
        #expect(sut.items(in: .today).map(\.id) == ["group:repeat", "task:other"])
        #expect(sut.groups(in: .earlier).isEmpty)
    }

    @Test func givenActiveWorkflows_whenOlderRunProgresses_thenCreationOrderStaysUnchanged() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        var older: [String: JSONValue] = ["workflow_run_id": .string("older"), "status": .string("running"),
                                        "created_at": .number(noon.addingTimeInterval(-7200).timeIntervalSince1970),
                                        "updated_at": .number(noon.addingTimeInterval(-7200).timeIntervalSince1970)]
        let newer = SidebarWorkflowRun(raw: ["workflow_run_id": .string("newer"), "status": .string("running"),
                                            "created_at": .number(noon.addingTimeInterval(-3600).timeIntervalSince1970)])
        sut.workflowRuns = [SidebarWorkflowRun(raw: older), newer]
        let before = sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: [])
        #expect(before.first?.items.map(\.id) == ["workflow:newer", "workflow:older"])
        // when
        older["updated_at"] = .number(noon.addingTimeInterval(-60).timeIntervalSince1970)
        sut.workflowRuns = [SidebarWorkflowRun(raw: older), newer]
        // then
        let after = sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: [])
        #expect(after.map(\.bucket) == [.running])
        #expect(after.first?.items.map(\.id) == before.first?.items.map(\.id))
    }

    @Test func givenYesterdayCompletedWorkflow_whenUpdatedToday_thenItStaysInEarlier() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        var run: [String: JSONValue] = ["workflow_run_id": .string("old"), "status": .string("completed"),
                                      "created_at": .number(noon.addingTimeInterval(-86400).timeIntervalSince1970),
                                      "updated_at": .number(noon.addingTimeInterval(-86400).timeIntervalSince1970)]
        sut.workflowRuns = [SidebarWorkflowRun(raw: run)]
        #expect(sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: []).first?.bucket == .earlier)
        // when
        run["updated_at"] = .number(noon.addingTimeInterval(-60).timeIntervalSince1970)
        sut.workflowRuns = [SidebarWorkflowRun(raw: run)]
        // then
        let sections = sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: [])
        #expect(sections.map(\.bucket) == [.earlier])
        #expect(sections.first?.items.map(\.id) == ["workflow:old"])
    }

    @Test func givenYesterdayWorkflowUpdatedToday_whenItStops_thenItReturnsToEarlier() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        var run: [String: JSONValue] = ["workflow_run_id": .string("repeat"), "status": .string("running"),
                                      "created_at": .number(noon.addingTimeInterval(-86400).timeIntervalSince1970),
                                      "updated_at": .number(noon.addingTimeInterval(-60).timeIntervalSince1970)]
        let today = SidebarWorkflowRun(raw: ["workflow_run_id": .string("today"), "status": .string("completed"),
                                            "created_at": .number(noon.addingTimeInterval(-3600).timeIntervalSince1970)])
        sut.workflowRuns = [SidebarWorkflowRun(raw: run), today]
        #expect(sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: []).first?.bucket == .running)
        // when
        run["status"] = .string("completed")
        sut.workflowRuns = [SidebarWorkflowRun(raw: run), today]
        // then
        let sections = sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: [])
        #expect(sections.map(\.bucket) == [.today, .earlier])
        #expect(sections.first?.items.map(\.id) == ["workflow:today"])
        #expect(sections.last?.items.map(\.id) == ["workflow:repeat"])
    }

    @Test func givenAGroupAndTasksInOneBucket_whenListed_thenTheyInterleaveNewestStartFirst() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        harness.tasksSubject.send([
            task(id: "older", status: "completed", startedAt: noon.addingTimeInterval(-7000)),
            task(id: "g1", status: "completed", startedAt: noon.addingTimeInterval(-5000), group: "mid"),
            task(id: "g2", status: "completed", startedAt: noon.addingTimeInterval(-4000), group: "mid"),
            task(id: "newer", status: "completed", startedAt: noon.addingTimeInterval(-100))
        ])

        // then
        await waitUntil { sut.items(in: .today).count == 3 }
        #expect(sut.items(in: .today).map(\.id) == ["task:newer", "group:mid", "task:older"])
    }

    @Test func givenARootWithNoStartTime_whenListed_thenItSortsLastInEarlier() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        harness.tasksSubject.send([
            task(id: "undated", status: "completed", startedAt: nil),
            task(id: "dated", status: "completed", startedAt: noon.addingTimeInterval(-2 * 86_400))
        ])

        // then
        await waitUntil { sut.rows(in: .earlier).count == 2 }
        #expect(sut.rows(in: .earlier).map(\.id) == ["dated", "undated"])
    }

    @Test func givenNoTasks_whenListed_thenNoSectionsExist() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        harness.tasksSubject.send([])
        harness.hasListedSubject.send(true)

        // then
        await waitUntil { sut.emptyStateMessage != nil }
        #expect(sut.sections.isEmpty)
    }

    // MARK: - Filter menu with zero results

    @Test func givenASearchWithNoResults_whenListed_thenTheBackendMenuModelIsStillAvailable() async {
        // given
        let harness = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()
        harness.hasListedSubject.send(true)
        harness.tasksSubject.send([task(id: "t1", status: "completed")])
        await waitUntil { !sut.sections.isEmpty }
        await sut.waitForPresentation()

        // when
        sut.didChangeSearchQuery("zzz-no-match")
        await sut.waitForPresentation()

        // then
        await waitUntil { sut.sections.isEmpty }
        await sut.waitForPresentation()
        #expect(sut.emptyStateMessage == "No tasks match \"zzz-no-match\".")
        #expect(sut.backendTabs.map(\.id).contains("codex"))
        #expect(sut.selectedBackend == "all")
    }

    @Test func givenAConnectedListing_whenAnErrorArrives_thenTheFooterStateFollows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()
        harness.hasListedSubject.send(true)
        await waitUntil { sut.isConnected }
        await sut.waitForPresentation()

        // when
        harness.listErrorSubject.send(ToolError.refused(code: "unreadable", message: "boom"))

        // then
        await waitUntil { !sut.isConnected }
        await sut.waitForPresentation()
        #expect(!sut.isConnected)
    }
}

// MARK: - Workflow run sort time: start or last resume

extension SidebarVMTests {
    private func resumeRun(_ id: String, status: String = "completed", createdAgo: TimeInterval,
                           resumedAgo: TimeInterval? = nil, extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var raw: [String: JSONValue] = ["workflow_run_id": .string(id), "status": .string(status),
                                        "created_at": .number(noon.addingTimeInterval(-createdAgo).timeIntervalSince1970)]
        if let resumedAgo { raw["resumed_at"] = .number(noon.addingTimeInterval(-resumedAgo).timeIntervalSince1970) }
        return raw.merging(extra) { _, new in new }
    }

    private func bucketed(_ sut: SidebarVM) -> [SidebarSection] {
        sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: [])
    }

    // Fails before the fix: latestRunAt ignores resumed_at.
    @Test func givenOldRunResumedRecently_whenBucketed_thenItSortsAboveNewerNeverResumedRun() async {
        // given
        let sut = makeBucketSUT().sut
        // when
        sut.workflowRuns = [
            SidebarWorkflowRun(raw: resumeRun("never-resumed", createdAgo: 3600)),
            SidebarWorkflowRun(raw: resumeRun("resumed", createdAgo: 7200, resumedAgo: 60))
        ]
        // then
        let sections = bucketed(sut)
        #expect(sections.map(\.bucket) == [.today])
        #expect(sections.first?.items.map(\.id) == ["workflow:resumed", "workflow:never-resumed"])
    }

    // Fails before the fix: the resume moves the run's day bucket.
    @Test func givenTerminalRunStartedEarlierResumedToday_whenBucketed_thenItLandsInToday() async {
        // given
        let sut = makeBucketSUT().sut
        // when
        sut.workflowRuns = [SidebarWorkflowRun(raw: resumeRun("resumed", createdAgo: 3 * 86_400, resumedAgo: 60))]
        // then
        let sections = bucketed(sut)
        #expect(sections.map(\.bucket) == [.today])
        #expect(sections.first?.items.map(\.id) == ["workflow:resumed"])
    }

    // The order check fails before the fix; the poll-state check passes and guards the recompute route.
    @Test func givenRetainedHeader_whenMergedWithResumedAt_thenPollStateDiffersAndBucketedOrderChanges() async {
        // given
        let sut = makeBucketSUT().sut
        sut.mergeWorkflowHeaders([resumeRun("old", createdAgo: 7200), resumeRun("new", createdAgo: 3600)])
        let stateBefore = sut.workflowPollState
        #expect(bucketed(sut).first?.items.map(\.id) == ["workflow:new", "workflow:old"])
        // when
        sut.mergeWorkflowHeaders([resumeRun("old", createdAgo: 7200, resumedAgo: 60)])
        // then
        #expect(sut.workflowPollState != stateBefore)
        #expect(bucketed(sut).first?.items.map(\.id) == ["workflow:old", "workflow:new"])
    }

    // Guard (passes before the fix): a newer updated_at alone never moves the run.
    @Test func givenRunWithNewerUpdatedAtOnly_whenBucketed_thenOrderAndBucketAreUnchanged() async {
        // given
        let sut = makeBucketSUT().sut
        let touched = resumeRun("touched", createdAgo: 3 * 86_400,
                                extra: ["updated_at": .number(noon.addingTimeInterval(-30).timeIntervalSince1970)])
        // when
        sut.workflowRuns = [SidebarWorkflowRun(raw: touched),
                            SidebarWorkflowRun(raw: resumeRun("newer", createdAgo: 3600))]
        // then
        let sections = bucketed(sut)
        #expect(sections.map(\.bucket) == [.today, .earlier])
        #expect(sections.first?.items.map(\.id) == ["workflow:newer"])
        #expect(sections.last?.items.map(\.id) == ["workflow:touched"])
    }

    // Guard (passes before the fix): resumed_at before created_at never moves the run backwards.
    @Test func givenResumedAtEarlierThanCreatedAt_whenBucketed_thenRunKeepsItsStartPosition() async {
        // given
        let sut = makeBucketSUT().sut
        // when
        sut.workflowRuns = [
            SidebarWorkflowRun(raw: resumeRun("skewed", createdAgo: 60, resumedAgo: 7200)),
            SidebarWorkflowRun(raw: resumeRun("other", createdAgo: 3600))
        ]
        // then
        #expect(bucketed(sut).first?.items.map(\.id) == ["workflow:skewed", "workflow:other"])
    }

    // Fails before the fix: resumed_at alone, with no created_at, must be the sort time.
    @Test func givenOnlyResumedAt_whenLatestRunAtRead_thenItIsTheResumeTime() {
        // given
        let stamp = noon.addingTimeInterval(-90)
        let run = SidebarWorkflowRun(raw: ["workflow_run_id": .string("r"),
                                           "resumed_at": .number(stamp.timeIntervalSince1970)])
        // when
        let value = run.latestRunAt
        // then
        #expect(value == stamp)
    }

    // Fails before the fix: resumed_at later than created_at wins.
    @Test func givenResumedAtLaterThanCreatedAt_whenLatestRunAtRead_thenItIsTheResumeTime() {
        // given
        let created = noon.addingTimeInterval(-7200)
        let resumed = noon.addingTimeInterval(-60)
        let run = SidebarWorkflowRun(raw: ["created_at": .number(created.timeIntervalSince1970),
                                           "resumed_at": .number(resumed.timeIntervalSince1970)])
        // when
        let value = run.latestRunAt
        // then
        #expect(value == resumed)
    }

    // Guard (passes before the fix): resumed_at earlier than created_at never lowers the sort time.
    @Test func givenResumedAtEarlierThanCreatedAt_whenLatestRunAtRead_thenItIsCreatedAt() {
        // given
        let created = noon.addingTimeInterval(-60)
        let resumed = noon.addingTimeInterval(-7200)
        let run = SidebarWorkflowRun(raw: ["created_at": .number(created.timeIntervalSince1970),
                                           "resumed_at": .number(resumed.timeIntervalSince1970)])
        // when
        let value = run.latestRunAt
        // then
        #expect(value == created)
    }

    // Guard (passes before the fix): unusable resumed_at values fall back to created_at.
    @Test(arguments: [JSONValue.string("soon"), .bool(true), .null, .number(.nan), .number(.infinity), .number(-.infinity)])
    func givenUnusableResumedAt_whenLatestRunAtRead_thenItFallsBackToCreatedAt(value: JSONValue) {
        // given
        let created = noon.addingTimeInterval(-7200)
        let run = SidebarWorkflowRun(raw: ["created_at": .number(created.timeIntervalSince1970), "resumed_at": value])
        // when
        let value = run.latestRunAt
        // then
        #expect(value == created)
    }

    // Guard (passes before the fix): absent resumed_at falls back to created_at; neither present is nil.
    @Test func givenNoResumedAt_whenLatestRunAtRead_thenItIsCreatedAtOrNil() {
        // given
        let created = noon.addingTimeInterval(-7200)
        // when
        let withCreated = SidebarWorkflowRun(raw: ["created_at": .number(created.timeIntervalSince1970)]).latestRunAt
        let empty = SidebarWorkflowRun(raw: [:]).latestRunAt
        // then
        #expect(withCreated == created)
        #expect(empty == nil)
    }
}
