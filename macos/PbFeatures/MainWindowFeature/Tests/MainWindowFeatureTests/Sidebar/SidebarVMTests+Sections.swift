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
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
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
        items(in: bucket).compactMap { if case .group(let group) = $0 { group } else { nil } }
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

        // when
        harness.tasksSubject.send([
            task(id: "run", status: "running", startedAt: noon.addingTimeInterval(-600)),
            task(id: "today", status: "completed", startedAt: noon.addingTimeInterval(-3600)),
            task(id: "old", status: "completed", startedAt: noon.addingTimeInterval(-3 * 86_400))
        ])

        // then
        await waitUntil { sut.sections.count == 3 }
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

        // when
        harness.tasksSubject.send([
            task(id: "root", status: "completed", startedAt: noon.addingTimeInterval(-3 * 86_400)),
            task(id: "child", status: "running", startedAt: noon.addingTimeInterval(-60), spawnedBy: "root")
        ])

        // then — the root stays Running even though it is old and finished; nothing is split off.
        await waitUntil { !sut.sections.isEmpty }
        #expect(sut.sections.map(\.bucket) == [.running])
        #expect(sut.runningRows.map(\.id) == ["root", "child"])
    }

    @Test func givenASettledTreeStartedYesterday_whenListed_thenItsDescendantsStayWithItInEarlier() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()

        // when — the child started today, but bucketing follows the root's start.
        harness.tasksSubject.send([
            task(id: "root", status: "completed", startedAt: noon.addingTimeInterval(-2 * 86_400)),
            task(id: "child", status: "completed", startedAt: noon.addingTimeInterval(-60), spawnedBy: "root")
        ])

        // then
        await waitUntil { !sut.sections.isEmpty }
        #expect(sut.sections.map(\.bucket) == [.earlier])
        #expect(sut.rows(in: .earlier).map(\.id) == ["root", "child"])
    }

    @Test func givenParallelGroups_whenListed_thenTheyBucketByRunningThenLatestMemberStart() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()

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

    @Test func givenYesterdayWorkflowContinuedToday_whenItStops_thenItStaysFirstInToday() {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        var run: [String: JSONValue] = ["workflow_run_id": .string("repeat"), "status": .string("running"),
                                      "created_at": .number(noon.addingTimeInterval(-86400).timeIntervalSince1970),
                                      "updated_at": .number(noon.addingTimeInterval(-60).timeIntervalSince1970)]
        let older = SidebarWorkflowRun(raw: ["workflow_run_id": .string("older"), "status": .string("completed"),
                                            "created_at": .number(noon.addingTimeInterval(-3600).timeIntervalSince1970)])
        sut.workflowRuns = [SidebarWorkflowRun(raw: run), older]
        #expect(sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: []).first?.bucket == .running)
        // when
        run["status"] = .string("completed")
        sut.workflowRuns = [SidebarWorkflowRun(raw: run), older]
        // then
        let sections = sut.bucketedSections(trees: [], groups: [], forcedExpandedIDs: [])
        #expect(sections.map(\.bucket) == [.today])
        #expect(sections.first?.items.map(\.id) == ["workflow:repeat", "workflow:older"])
    }

    @Test func givenAGroupAndTasksInOneBucket_whenListed_thenTheyInterleaveNewestStartFirst() async {
        // given
        let harness = makeBucketSUT()
        let sut = harness.sut
        sut.didAppear()

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
        harness.hasListedSubject.send(true)
        harness.tasksSubject.send([task(id: "t1", status: "completed")])
        await waitUntil { !sut.sections.isEmpty }

        // when
        sut.didChangeSearchQuery("zzz-no-match")

        // then
        await waitUntil { sut.sections.isEmpty }
        #expect(sut.emptyStateMessage == "No tasks match \"zzz-no-match\".")
        #expect(sut.backendTabs.map(\.id).contains("codex"))
        #expect(sut.selectedBackend == "all")
    }

    @Test func givenAConnectedListing_whenAnErrorArrives_thenTheFooterStateFollows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        await waitUntil { sut.isConnected }

        // when
        harness.listErrorSubject.send(ToolError.refused(code: "unreadable", message: "boom"))

        // then
        await waitUntil { !sut.isConnected }
        #expect(!sut.isConnected)
    }
}
