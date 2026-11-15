//
//  TaskTopBarSlotHolderTests.swift
//  MainWindowFeatureTests
//

import Foundation
@testable import MainWindowFeature
import Observation
import Testing

// MARK: - TaskTopBarSlotHolderTests

/// The task slot states the holder carries: loading, loaded and not found for the shown writer, and the coordinator's
/// pre-mount slot, each written only when it changes.
@MainActor
@Suite struct TaskTopBarSlotHolderTests {
    private typealias Fixtures = TopBarFixtures

    private final class Flag: @unchecked Sendable {
        var fired = false
    }

    private func activeHolder(conversation: String = "a") -> (holder: TaskTopBarHolder, tag: TaskTopBarHolder.Tag) {
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), conversation)
        holder.setShownConversation(conversation)
        holder.activate(tag)
        return (holder, tag)
    }

    // MARK: - Slot

    @Test func givenEachSlotState_whenReadingItsLoadedContent_thenOnlyLoadedCarriesIt() {
        // given
        let content = Fixtures.content(title: "A")

        // when / then
        #expect(TaskTopBarSlot.loaded(content).content == content)
        #expect(TaskTopBarSlot.loading(title: "A").content == nil)
        #expect(TaskTopBarSlot.loading(title: nil).content == nil)
        #expect(TaskTopBarSlot.notFound.content == nil)
    }

    @Test func givenLoadingStatesOfDifferentTitles_whenCompared_thenTheyAreDistinct() {
        // given / when / then
        #expect(TaskTopBarSlot.loading(title: nil) != .loading(title: "A"))
        #expect(TaskTopBarSlot.loading(title: "A") != .loading(title: "B"))
        #expect(TaskTopBarSlot.loading(title: "A") == .loading(title: "A"))
        #expect(TaskTopBarSlot.loading(title: nil) != .notFound)
    }

    // MARK: - Shown slot

    @Test func givenAnActiveWriter_whenItPublishesTheLoadingSlot_thenTheSlotIsShownAndNoContentIs() {
        // given
        let (holder, tag) = activeHolder()

        // when
        holder.publish(slot: .loading(title: "Known"), tag: tag)

        // then
        #expect(holder.shownSlot == .loading(title: "Known"))
        #expect(holder.shown == nil)
    }

    @Test func givenAnActiveWriter_whenItPublishesNotFound_thenThatSlotIsShownAndNoContentIs() {
        // given
        let (holder, tag) = activeHolder()

        // when
        holder.publish(slot: .notFound, tag: tag)

        // then
        #expect(holder.shownSlot == .notFound)
        #expect(holder.shown == nil)
    }

    @Test func givenAnActiveWriter_whenItPublishesContent_thenTheShownSlotIsTheLoadedState() {
        // given
        let (holder, tag) = activeHolder()
        let content = Fixtures.content(title: "A")

        // when
        holder.publish(content, tag: tag)

        // then
        #expect(holder.shownSlot == .loaded(content))
        #expect(holder.shown == content)
    }

    @Test func givenALoadingSlot_whenLoadedContentThenLoadingAreWritten_thenEachTransitionIsShown() {
        // given
        let (holder, tag) = activeHolder()
        let content = Fixtures.content(title: "A")
        holder.publish(slot: .loading(title: nil), tag: tag)

        // when
        holder.publish(content, tag: tag)

        // then
        #expect(holder.shown == content)

        // when the task goes missing again
        holder.publish(slot: .loading(title: nil), tag: tag)

        // then
        #expect(holder.shownSlot == .loading(title: nil))
        #expect(holder.shown == nil)
    }

    @Test func givenAShownLoadingSlot_whenTheSameSlotIsPublishedAgain_thenObserversAreNotNotified() {
        // given
        let (holder, tag) = activeHolder()
        holder.publish(slot: .loading(title: "Known"), tag: tag)
        let flag = Flag()
        withObservationTracking { _ = holder.shownSlot } onChange: { flag.fired = true }

        // when
        holder.publish(slot: .loading(title: "Known"), tag: tag)

        // then
        #expect(!flag.fired)
    }

    @Test func givenAShownLoadingSlot_whenTheTitleArrives_thenObserversAreNotified() {
        // given
        let (holder, tag) = activeHolder()
        holder.publish(slot: .loading(title: nil), tag: tag)
        let flag = Flag()
        withObservationTracking { _ = holder.shownSlot } onChange: { flag.fired = true }

        // when
        holder.publish(slot: .loading(title: "Known"), tag: tag)

        // then
        #expect(flag.fired)
        #expect(holder.shownSlot == .loading(title: "Known"))
    }

    @Test func givenAShownLoadingSlot_whenItsWriterClears_thenNothingIsShown() {
        // given
        let (holder, tag) = activeHolder()
        holder.publish(slot: .loading(title: "Known"), tag: tag)

        // when
        holder.clear(tag: tag)

        // then
        #expect(holder.shownSlot == nil)
    }

    @Test func givenALoadingSlotOfAnInactiveWriter_whenItIsActivated_thenItIsShownAfterwards() {
        // given
        let holder = TaskTopBarHolder()
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(slot: .loading(title: "Known"), tag: tag)
        #expect(holder.shownSlot == nil)

        // when
        holder.activate(tag)

        // then
        #expect(holder.shownSlot == .loading(title: "Known"))
    }

    @Test func givenAShownSlotOfOneConversation_whenTheShownConversationChanges_thenTheSlotIsDropped() {
        // given
        let (holder, tag) = activeHolder()
        holder.publish(slot: .loading(title: "Known"), tag: tag)

        // when
        holder.setShownConversation("b")

        // then
        #expect(holder.shownSlot == nil)
        #expect(holder.activeTag == nil)
    }

    @Test func givenALateSlotWriteFromAnOutgoingWriter_whenAnotherWriterIsShown_thenTheLateWriteStaysHidden() {
        // given
        let holder = TaskTopBarHolder()
        let outgoing = Fixtures.tag(Fixtures.Writer(), "a")
        let incoming = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.publish(slot: .loading(title: "First"), tag: outgoing)
        holder.activate(outgoing)
        holder.publish(slot: .loading(title: "Second"), tag: incoming)
        holder.activate(incoming)

        // when
        holder.publish(slot: .notFound, tag: outgoing)

        // then
        #expect(holder.shownSlot == .loading(title: "Second"))
    }

    // MARK: - Pre-mount slot

    @Test func givenNoPreMountSlot_whenTheHolderIsCreated_thenItIsNil() {
        // given / when
        let holder = TaskTopBarHolder()

        // then
        #expect(holder.preMountSlot == nil)
        #expect(holder.shownSlot == nil)
    }

    @Test func givenAPreMountSlot_whenItIsSet_thenItIsReadableWithoutAWriter() {
        // given
        let holder = TaskTopBarHolder()

        // when
        holder.setPreMountSlot(.loading(title: "Known"))

        // then
        #expect(holder.preMountSlot == .loading(title: "Known"))
        #expect(holder.shownSlot == nil)
        #expect(holder.shown == nil)
    }

    @Test func givenAPreMountSlot_whenTheSameValueIsSetAgain_thenObserversAreNotNotified() {
        // given
        let holder = TaskTopBarHolder()
        holder.setPreMountSlot(.loading(title: nil))
        let flag = Flag()
        withObservationTracking { _ = holder.preMountSlot } onChange: { flag.fired = true }

        // when
        holder.setPreMountSlot(.loading(title: nil))

        // then
        #expect(!flag.fired)
    }

    @Test func givenAPreMountSlot_whenAnotherValueIsSet_thenObserversAreNotified() {
        // given
        let holder = TaskTopBarHolder()
        holder.setPreMountSlot(.loading(title: nil))
        let flag = Flag()
        withObservationTracking { _ = holder.preMountSlot } onChange: { flag.fired = true }

        // when
        holder.setPreMountSlot(.loading(title: "Known"))

        // then
        #expect(flag.fired)
    }

    @Test func givenAPreMountSlot_whenItIsClearedToNil_thenObserversAreNotifiedOnceAndAFurtherNilIsSilent() {
        // given
        let holder = TaskTopBarHolder()
        holder.setPreMountSlot(.loading(title: "Known"))
        let cleared = Flag()
        withObservationTracking { _ = holder.preMountSlot } onChange: { cleared.fired = true }

        // when
        holder.setPreMountSlot(nil)

        // then
        #expect(cleared.fired)
        #expect(holder.preMountSlot == nil)

        // when the nil is written again
        let silent = Flag()
        withObservationTracking { _ = holder.preMountSlot } onChange: { silent.fired = true }
        holder.setPreMountSlot(nil)

        // then
        #expect(!silent.fired)
    }

    @Test func givenAPreMountSlot_whenWritersPublishAndTheShownConversationChanges_thenItIsLeftToTheCoordinator() {
        // given
        let holder = TaskTopBarHolder()
        holder.setPreMountSlot(.loading(title: "Known"))
        let tag = Fixtures.tag(Fixtures.Writer(), "a")
        holder.setShownConversation("a")
        holder.activate(tag)

        // when
        holder.publish(Fixtures.content(title: "A"), tag: tag)
        holder.clear(tag: tag)
        holder.setShownConversation("b")

        // then
        #expect(holder.preMountSlot == .loading(title: "Known"))
    }

    @Test func givenAPreMountSlotAndAShownWriter_whenReadingBoth_thenTheyAreIndependentFields() {
        // given
        let (holder, tag) = activeHolder()
        holder.setPreMountSlot(.loading(title: "From listing"))

        // when
        holder.publish(slot: .notFound, tag: tag)

        // then the principal reads `shownSlot ?? preMountSlot`: the writer's state wins
        #expect(holder.shownSlot == .notFound)
        #expect(holder.preMountSlot == .loading(title: "From listing"))
        #expect((holder.shownSlot ?? holder.preMountSlot) == .notFound)
    }
}
