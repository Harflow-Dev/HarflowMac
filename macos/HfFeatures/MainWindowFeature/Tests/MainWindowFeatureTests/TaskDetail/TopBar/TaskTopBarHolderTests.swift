//
//  TaskTopBarHolderTests.swift
//  MainWindowFeatureTests
//

import Foundation
@testable import MainWindowFeature
import Observation
import Testing

// MARK: - TaskTopBarHolderTests

/// The transport's own rules: one active writer for the shown conversation, tag-scoped clears, and writes that happen
/// only when what is shown changes.
@MainActor
@Suite struct TaskTopBarHolderTests {
    private typealias Fixtures = TopBarFixtures

    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    // MARK: - Activation

    @Test func givenAPublishedEntry_whenNoWriterIsActive_thenNothingIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let writer = Fixtures.Writer()
        holder.setShownConversation("a")

        // when
        holder.publish(Fixtures.content(title: "A"), tag: Fixtures.tag(writer, "a"))

        // then
        #expect(holder.shown == nil)
    }

    @Test func givenTheShownConversation_whenItsWriterActivates_thenItsContentIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: tag)

        // when
        let accepted = holder.activate(tag)

        // then
        #expect(accepted)
        #expect(holder.activeTag == tag)
        #expect(holder.shown?.title == "A")
    }

    @Test func givenAnotherConversationShown_whenAWriterActivates_thenItIsRefused() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("b")
        holder.publish(Fixtures.content(title: "A"), tag: tag)

        // when
        let accepted = holder.activate(tag)

        // then
        #expect(!accepted)
        #expect(holder.activeTag == nil)
        #expect(holder.shown == nil)
    }

    @Test func givenNoShownConversation_whenAWriterActivates_thenItIsRefused() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")

        // when
        let accepted = holder.activate(tag)

        // then
        #expect(!accepted)
        #expect(holder.shownConversation == nil)
        #expect(holder.shown == nil)
    }

    @Test func givenAnActiveWriter_whenItPublishesNewContent_thenTheNewContentIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.activate(tag)
        holder.publish(Fixtures.content(title: "First"), tag: tag)

        // when
        holder.publish(Fixtures.content(title: "Second"), tag: tag)

        // then
        #expect(holder.shown?.title == "Second")
    }

    // MARK: - Shown conversation

    @Test func givenAnActiveWriter_whenTheShownConversationChanges_thenTheActiveWriterAndContentAreDropped() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: tag)
        holder.activate(tag)

        // when
        holder.setShownConversation("b")

        // then A's content never flashes over B
        #expect(holder.activeTag == nil)
        #expect(holder.shown == nil)
        #expect(holder.shownConversation == "b")
    }

    @Test func givenEntriesOfOtherConversations_whenTheShownConversationChanges_thenTheyArePruned() {
        // given
        let holder = TaskTopBarHolder()
        let tagA = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: tagA)

        // when going away and coming back without A republishing
        holder.setShownConversation("b")
        holder.setShownConversation("a")
        holder.activate(tagA)

        // then the stale entry was pruned
        #expect(holder.shown == nil)
    }

    @Test func givenTheSameShownConversation_whenItIsSetAgain_thenTheActiveWriterIsKept() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: tag)
        holder.activate(tag)

        // when
        holder.setShownConversation("a")

        // then
        #expect(holder.activeTag == tag)
        #expect(holder.shown?.title == "A")
    }

    @Test func givenANonTaskSelection_whenTheShownConversationIsNil_thenNothingIsShownAndLateWritesStayHidden() {
        // given
        let holder = TaskTopBarHolder()
        let writer = Fixtures.Writer()
        let tag = Fixtures.tag(writer, "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: tag)
        holder.activate(tag)

        // when
        holder.setShownConversation(nil)
        holder.publish(Fixtures.content(title: "Late A"), tag: tag)

        // then
        #expect(holder.shown == nil)
        #expect(holder.activate(tag) == false)
        #expect(holder.shown == nil)
    }

    // MARK: - Clearing and deactivating

    @Test func givenTheActiveWritersEntry_whenItIsCleared_thenNothingIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: tag)
        holder.activate(tag)

        // when
        holder.clear(tag: tag)

        // then
        #expect(holder.shown == nil)
        #expect(holder.activeTag == tag)
    }

    @Test func givenAnActiveWriter_whenADifferentWritersTagClears_thenTheClearIsIgnored() {
        // given
        let holder = TaskTopBarHolder()
        let active = Fixtures.tag(Fixtures.Writer(), "a")
        let mismatched = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: active)
        holder.activate(active)

        // when
        holder.clear(tag: mismatched)

        // then
        #expect(holder.shown?.title == "A")
    }

    @Test func givenAnActiveWriter_whenTheSameWriterClearsWithAnotherConversationTag_thenTheClearIsIgnored() {
        // given
        let holder = TaskTopBarHolder()
        let writer = Fixtures.Writer()
        let active = Fixtures.tag(writer, "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: active)
        holder.activate(active)

        // when
        holder.clear(tag: Fixtures.tag(writer, "b"))

        // then
        #expect(holder.shown?.title == "A")
    }

    @Test func givenAnActiveWriter_whenAnotherWriterDeactivates_thenItStaysActive() {
        // given
        let holder = TaskTopBarHolder()
        let active = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: active)
        holder.activate(active)

        // when
        holder.deactivate(Fixtures.tag(Fixtures.Writer(), "a"))

        // then
        #expect(holder.activeTag == active)
        #expect(holder.shown?.title == "A")
    }

    @Test func givenAnActiveWriter_whenItDeactivates_thenNothingIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: tag)
        holder.activate(tag)

        // when
        holder.deactivate(tag)

        // then
        #expect(holder.activeTag == nil)
        #expect(holder.shown == nil)
    }

    // MARK: - Generations of one conversation (A, B, A)

    @Test func givenTwoGenerationsOfOneConversation_whenTheFirstWritesAndClearsLate_thenTheSecondStaysShown() {
        // given the first generation of A was shown, B replaced it, and a second A is active
        let holder = TaskTopBarHolder()
        let first = Fixtures.tag(Fixtures.Writer(), "a")
        let second = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "First A"), tag: first)
        holder.activate(first)
        holder.setShownConversation("b")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "Second A"), tag: second)
        holder.activate(second)

        // when the outgoing generation writes, clears and deactivates late
        holder.publish(Fixtures.content(title: "Late first A"), tag: first)
        #expect(holder.shown?.title == "Second A")
        holder.clear(tag: first)
        holder.deactivate(first)

        // then
        #expect(holder.activeTag == second)
        #expect(holder.shown?.title == "Second A")
    }

    // MARK: - Writes only on change

    @Test func givenShownContent_whenIdenticalContentIsPublished_thenTheShownValueIsNotWritten() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.activate(tag)
        holder.publish(Fixtures.content(title: "A"), tag: tag)
        let flag = Flag()
        withObservationTracking { _ = holder.shown } onChange: { flag.fired = true }

        // when
        holder.publish(Fixtures.content(title: "A"), tag: tag)

        // then
        #expect(!flag.fired)
    }

    @Test func givenShownContent_whenDifferentContentIsPublished_thenObserversAreNotified() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.activate(tag)
        holder.publish(Fixtures.content(title: "A"), tag: tag)
        let flag = Flag()
        withObservationTracking { _ = holder.shown } onChange: { flag.fired = true }

        // when
        holder.publish(Fixtures.content(title: "B"), tag: tag)

        // then
        #expect(flag.fired)
    }

    @Test func givenAnEmptyHolder_whenAnUnknownTagClearsOrDeactivates_thenNothingChanges() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        let flag = Flag()
        withObservationTracking { _ = holder.shown } onChange: { flag.fired = true }

        // when
        holder.clear(tag: tag)
        holder.deactivate(tag)

        // then
        #expect(!flag.fired)
        #expect(holder.shown == nil)
    }

    // MARK: - activateIfVacant

    @Test func givenNoActiveWriter_whenTheShownConversationsWriterAsks_thenItIsAccepted() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "A"), tag: tag)

        // when
        let accepted = holder.activateIfVacant(tag)

        // then
        #expect(accepted)
        #expect(holder.shown?.title == "A")
    }

    @Test func givenAnotherConversationShown_whenAWriterAsksIfVacant_thenItIsRefused() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("b")

        // when / then
        #expect(!holder.activateIfVacant(tag))
        #expect(holder.activeTag == nil)
    }

    @Test func givenADifferentActiveWriterOfTheShownConversation_whenAnotherAsksIfVacant_thenItNeverReplacesIt() {
        // given
        let holder = TaskTopBarHolder()
        let active = Fixtures.tag(Fixtures.Writer(), "a")
        let stale = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(Fixtures.content(title: "Active"), tag: active)
        holder.publish(Fixtures.content(title: "Stale"), tag: stale)
        holder.activate(active)

        // when
        let accepted = holder.activateIfVacant(stale)

        // then
        #expect(!accepted)
        #expect(holder.activeTag == active)
        #expect(holder.shown?.title == "Active")
    }

    @Test func givenTheActiveWriter_whenItAsksIfVacant_thenItStaysAccepted() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.activate(tag)

        // when / then
        #expect(holder.activateIfVacant(tag))
        #expect(holder.activeTag == tag)
    }

    // MARK: - Page content

    /// Writers stay alive for the process so two tags never share a reused object identity.
    private static var retainedWriters: [Fixtures.Writer] = []

    private func pageTag(_ writer: Fixtures.Writer) -> TaskTopBarHolder.Tag {
        Self.retainedWriters.append(writer)
        return TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), subject: .pendingLaunches)
    }

    @Test func givenThePendingLaunchesPage_whenItsWriterPublishesAndActivates_thenOnlyThePageContentIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let writer = Fixtures.Writer()
        let tag = pageTag(writer)
        holder.setShownSubject(.pendingLaunches)
        holder.publish(PageTopBarContent.pendingLaunches(title: "Review checks"), tag: tag)
        #expect(holder.shownPage == nil)

        // when
        let accepted = holder.activate(tag)

        // then
        #expect(accepted)
        #expect(holder.shownPage?.title == "Review checks")
        #expect(holder.shownPage?.badge == .pendingLaunch)
        #expect(holder.shown == nil)
        #expect(holder.shownGroup == nil)
    }

    @Test func givenAnotherSubjectShown_whenThePageWriterActivates_thenItIsRefusedAndNothingIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let tag = pageTag(Fixtures.Writer())
        holder.setShownSubject(.group("release"))
        holder.publish(PageTopBarContent.pendingLaunchesInventory, tag: tag)

        // when / then
        #expect(!holder.activate(tag))
        #expect(!holder.activateIfVacant(tag))
        #expect(holder.shownPage == nil)
    }

    @Test func givenShownPageContent_whenTheSelectionLeavesThePage_thenItIsDroppedAndDoesNotReturnWithoutAFreshWrite() {
        // given
        let holder = TaskTopBarHolder()
        let tag = pageTag(Fixtures.Writer())
        holder.setShownSubject(.pendingLaunches)
        holder.activate(tag)
        holder.publish(PageTopBarContent.pendingLaunchesInventory, tag: tag)
        #expect(holder.shownPage != nil)

        // when
        holder.setShownConversation("a")
        holder.setShownSubject(.pendingLaunches)

        // then
        #expect(holder.shownPage == nil)
        #expect(holder.activeTag == nil)
    }

    @Test func givenShownPageContent_whenDifferentContentIsPublished_thenTheShownTitleFollows() {
        // given
        let holder = TaskTopBarHolder()
        let tag = pageTag(Fixtures.Writer())
        holder.setShownSubject(.pendingLaunches)
        holder.activate(tag)
        holder.publish(PageTopBarContent.pendingLaunchesInventory, tag: tag)

        // when
        holder.publish(PageTopBarContent.pendingLaunches(title: "Prepare local environment"), tag: tag)

        // then
        #expect(holder.shownPage?.title == "Prepare local environment")
    }

    @Test func givenShownPageContent_whenTheSameContentIsPublishedAgain_thenObserversAreNotNotified() {
        // given
        let holder = TaskTopBarHolder()
        let tag = pageTag(Fixtures.Writer())
        holder.setShownSubject(.pendingLaunches)
        holder.activate(tag)
        holder.publish(PageTopBarContent.pendingLaunchesInventory, tag: tag)
        let flag = Flag()
        withObservationTracking { _ = holder.shownPage } onChange: { flag.fired = true }

        // when
        holder.publish(PageTopBarContent.pendingLaunchesInventory, tag: tag)

        // then
        #expect(!flag.fired)
    }

    @Test func givenShownPageContent_whenDifferentContentIsPublished_thenObserversAreNotified() {
        // given
        let holder = TaskTopBarHolder()
        let tag = pageTag(Fixtures.Writer())
        holder.setShownSubject(.pendingLaunches)
        holder.activate(tag)
        holder.publish(PageTopBarContent.pendingLaunchesInventory, tag: tag)
        let flag = Flag()
        withObservationTracking { _ = holder.shownPage } onChange: { flag.fired = true }

        // when
        holder.publish(PageTopBarContent.pendingLaunches(title: "Other"), tag: tag)

        // then
        #expect(flag.fired)
    }

    @Test func givenShownPageContent_whenTheWriterDeactivatesOrClears_thenNothingIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let tag = pageTag(Fixtures.Writer())
        holder.setShownSubject(.pendingLaunches)
        holder.activate(tag)
        holder.publish(PageTopBarContent.pendingLaunchesInventory, tag: tag)

        // when
        holder.deactivate(tag)

        // then
        #expect(holder.shownPage == nil)

        // when: it activates again with its stored content, then clears.
        holder.activate(tag)
        #expect(holder.shownPage != nil)
        holder.clear(tag: tag)

        // then
        #expect(holder.shownPage == nil)
    }

    @Test func givenAnActivePageWriter_whenAnotherWriterOfTheSameSubjectActivates_thenOnlyTheLatestIsShown() {
        // given
        let holder = TaskTopBarHolder()
        let first = pageTag(Fixtures.Writer())
        let second = pageTag(Fixtures.Writer())
        holder.setShownSubject(.pendingLaunches)
        holder.publish(PageTopBarContent.pendingLaunches(title: "First"), tag: first)
        holder.publish(PageTopBarContent.pendingLaunches(title: "Second"), tag: second)
        holder.activate(first)

        // when
        holder.activate(second)

        // then
        #expect(holder.shownPage?.title == "Second")
        // and a late write from the outgoing writer is stored but not shown
        holder.publish(PageTopBarContent.pendingLaunches(title: "Late"), tag: first)
        #expect(holder.shownPage?.title == "Second")
    }

    @Test func givenAPageTag_whenAskingForItsConversationID_thenItIsAFixedKey() {
        // given / when / then
        #expect(pageTag(Fixtures.Writer()).conversationID == "pending-launches")
    }

    @Test func givenThePageContent_whenBuilt_thenItCarriesTheInventoryTitleAndTheBaseToneBadge() {
        // given / when / then
        #expect(PageTopBarContent.pendingLaunchesTitle == "Pending launches")
        #expect(PageTopBarContent.pendingLaunchesInventory == PageTopBarContent.pendingLaunches(title: "Pending launches"))
        #expect(TaskBadgeModel.pendingLaunch.label == "Pending launch")
        #expect(TaskBadgeModel.pendingLaunch.tone == .base)
        #expect(TaskBadgeModel.pendingLaunch.clock == .none)
    }
}
