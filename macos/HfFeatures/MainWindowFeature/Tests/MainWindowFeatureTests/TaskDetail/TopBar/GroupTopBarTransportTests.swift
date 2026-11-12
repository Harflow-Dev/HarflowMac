//
//  GroupTopBarTransportTests.swift
//  MainWindowFeatureTests
//

import Foundation
@testable import MainWindowFeature
import MonitorCore
import Observation
import Testing

// MARK: - GroupTopBarTransportTests

/// A Parallel group's content travels the standalone task's transport: subject-keyed writers, one active writer for
/// the shown subject, and writes only when the content changes.
@MainActor
@Suite struct GroupTopBarTransportTests {
    private final class Flag: @unchecked Sendable { var fired = false }

    private func content(_ title: String, badge: String = "1 running") -> GroupTopBarContent {
        GroupTopBarContent(title: title, badge: TaskBadgeModel.group(counts(running: 1)), meta: "meta \(badge)")
    }

    private func counts(running: Int = 0, done: Int = 0, failed: Int = 0, cancelled: Int = 0) -> ParallelStatusCounts {
        func tasks(_ status: String, _ count: Int) -> [TaskInfo] {
            (0 ..< count).map { TaskInfo(.object(["task_id": .string("\(status)\($0)"), "status": .string(status)]))! }
        }
        return ParallelStatusCounts(tasks: tasks("running", running) + tasks("completed", done) + tasks("failed", failed) + tasks("cancelled", cancelled))
    }

    private func tag(_ writer: TopBarFixtures.Writer, group: String) -> TaskTopBarHolder.Tag {
        TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), subject: .group(group))
    }

    // MARK: - Subject isolation

    @Test func givenAGroupWriter_whenItActivatesForTheShownGroup_thenItsContentIsShownAndTaskContentIsNot() {
        // given
        let holder = TaskTopBarHolder()
        let writer = TopBarFixtures.Writer()
        let groupTag = tag(writer, group: "g")
        holder.setShownSubject(.group("g"))

        // when
        holder.publish(content("g"), tag: groupTag)
        holder.activate(groupTag)

        // then
        #expect(holder.shownGroup?.title == "g")
        #expect(holder.shown == nil)
        #expect(holder.shownSubject == .group("g"))
        #expect(holder.shownConversation == nil)
    }

    @Test func givenAGroupAndATaskWithTheSameName_whenOnlyTheTaskIsShown_thenTheGroupWriterIsRefused() {
        // given
        let holder = TaskTopBarHolder()
        let writer = TopBarFixtures.Writer()
        holder.setShownSubject(.task("same"))

        // when
        holder.publish(content("same"), tag: tag(writer, group: "same"))

        // then
        #expect(!holder.activate(tag(writer, group: "same")))
        #expect(holder.shownGroup == nil)
    }

    @Test func givenGroupA_whenTheShownGroupBecomesB_thenTheActiveTagIsDroppedAndOnlyBsWriterCanShow() {
        // given
        let holder = TaskTopBarHolder()
        let first = TopBarFixtures.Writer()
        let second = TopBarFixtures.Writer()
        holder.setShownSubject(.group("a"))
        holder.publish(content("a"), tag: tag(first, group: "a"))
        holder.activate(tag(first, group: "a"))
        #expect(holder.shownGroup?.title == "a")

        // when
        holder.setShownSubject(.group("b"))

        // then — a never flashes over b
        #expect(holder.activeTag == nil)
        #expect(holder.shownGroup == nil)
        holder.publish(content("b"), tag: tag(second, group: "b"))
        #expect(holder.shownGroup == nil, "stored but not shown until its writer activates")
        holder.activate(tag(second, group: "b"))
        #expect(holder.shownGroup?.title == "b")
    }

    @Test func givenAStaleGroupWriter_whenItPublishesAfterTheGroupChanged_thenItIsStoredButNeverShown() {
        // given
        let holder = TaskTopBarHolder()
        let stale = TopBarFixtures.Writer()
        holder.setShownSubject(.group("a"))
        holder.setShownSubject(.group("b"))

        // when
        holder.publish(content("a"), tag: tag(stale, group: "a"))
        holder.activate(tag(stale, group: "a"))

        // then
        #expect(holder.shownGroup == nil)
        #expect(holder.activeTag == nil)
    }

    // MARK: - Writes only on change

    @Test func givenShownGroupContent_whenIdenticalContentIsPublishedAgain_thenNothingIsObservedToChange() {
        // given
        let holder = TaskTopBarHolder()
        let writer = TopBarFixtures.Writer()
        let groupTag = tag(writer, group: "g")
        holder.setShownSubject(.group("g"))
        holder.publish(content("g"), tag: groupTag)
        holder.activate(groupTag)
        let flag = Flag()
        withObservationTracking { _ = holder.shownGroup; _ = holder.shown } onChange: { flag.fired = true }

        // when
        holder.publish(content("g"), tag: groupTag)

        // then
        #expect(!flag.fired)
    }

    @Test func givenShownGroupContent_whenItChanges_thenTheShownValueIsObservedToChange() {
        // given
        let holder = TaskTopBarHolder()
        let writer = TopBarFixtures.Writer()
        let groupTag = tag(writer, group: "g")
        holder.setShownSubject(.group("g"))
        holder.publish(content("g"), tag: groupTag)
        holder.activate(groupTag)
        let flag = Flag()
        withObservationTracking { _ = holder.shownGroup } onChange: { flag.fired = true }

        // when
        holder.publish(content("g renamed"), tag: groupTag)

        // then
        #expect(flag.fired)
        #expect(holder.shownGroup?.title == "g renamed")
    }

    // MARK: - Handoff

    @Test func givenLoadingThenLoadedContent_whenTheSameWriterPublishes_thenTheShownContentNeverBecomesNil() {
        // given
        let holder = TaskTopBarHolder()
        let writer = TopBarFixtures.Writer()
        let groupTag = tag(writer, group: "g")
        holder.setShownSubject(.group("g"))

        // when — the VM publishes before it activates, then replaces its content in place
        holder.publish(GroupTopBarContent(title: "g", badge: nil, meta: nil, isLoading: true), tag: groupTag)
        holder.activate(groupTag)
        var seen = [holder.shownGroup]
        holder.publish(content("g"), tag: groupTag)
        seen.append(holder.shownGroup)

        // then
        #expect(seen.allSatisfy { $0 != nil })
        #expect(seen.first??.isLoading == true)
        #expect(seen.last??.isLoading == false)
    }

    // MARK: - Badge

    @Test func givenStatusCounts_whenBuildingTheGroupBadge_thenToneAndIconFollowTheDrawnStates() {
        func badge(_ counts: ParallelStatusCounts) -> TaskBadgeModel? { TaskBadgeModel.group(counts) }
        #expect(badge(counts(running: 1, done: 2))?.tone == .running)
        #expect(badge(counts(running: 1, done: 2))?.icon == .spinner)
        #expect(badge(counts(running: 1, done: 2))?.label == "1 running · 2 done")
        #expect(badge(counts(done: 3))?.tone == .done)
        #expect(badge(counts(done: 3))?.icon == TaskBadgeModel.Icon.none)
        #expect(badge(counts(done: 3))?.label == "3 done")
        #expect(badge(counts(done: 2, failed: 1))?.tone == .failed)
        #expect(badge(counts(done: 2, failed: 1))?.label == "2 done · 1 failed")
        #expect(badge(counts(done: 2, cancelled: 1))?.tone == .neutral)
        #expect(badge(counts(done: 2, cancelled: 1))?.label == "2 done · 1 cancelled")
        #expect(badge(counts(running: 1, done: 1))?.label == "1 running · 1 done")
        #expect(badge(counts(failed: 1, cancelled: 1))?.tone == .failed, "failed outranks cancelled")
    }

    @Test func givenTimedOutAndEmptyMembership_whenCounting_thenTimedOutIsFailedAndEmptyHasNoBadge() {
        // given / when
        let timedOut = ParallelStatusCounts(tasks: [TaskInfo(.object(["task_id": .string("t"), "status": .string("timed_out")]))!])

        // then
        #expect(timedOut.failed == 1)
        #expect(TaskBadgeModel.group(timedOut)?.label == "1 failed")
        #expect(TaskBadgeModel.group(ParallelStatusCounts(tasks: [])) == nil)
    }
}
