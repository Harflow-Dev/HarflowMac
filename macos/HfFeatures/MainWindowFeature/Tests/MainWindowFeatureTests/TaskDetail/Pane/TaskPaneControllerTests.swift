//
//  TaskPaneControllerTests.swift
//  MainWindowFeatureTests
//

import Foundation
@testable import MainWindowFeature
import Observation
import Testing

// MARK: - TaskPaneControllerTests

@MainActor
struct TaskPaneControllerTests {
    private typealias Controller = TaskPaneController
    private static let conversation = "conv"

    /// Counts Observation notifications of one read, re-arming after each.
    @MainActor
    private final class Tracker {
        private(set) var fired = 0
        private let read: () -> Void

        init(_ read: @escaping () -> Void) {
            self.read = read
            arm()
        }

        private func arm() {
            withObservationTracking {
                read()
            } onChange: { [weak self] in
                MainActor.assumeIsolated {
                    self?.fired += 1
                    self?.arm()
                }
            }
        }
    }

    private func make(id: String = conversation, store: TaskPaneStateStore = TaskPaneStateStore()) -> (Controller, TaskPaneStateStore) {
        (Controller(store: store, conversationID: id), store)
    }

    private static let opensAtSplit = Controller.DefaultInput(isReady: true, opensAtSplit: true)
    private static let closedDefault = Controller.DefaultInput(isReady: true, opensAtSplit: false)

    // MARK: - Measurement and mode

    @Test func givenNoMeasurement_whenRead_thenThereIsNoModeAndThePaneIsClosed() {
        // given
        let (sut, _) = make()

        // when / then
        #expect(sut.mode == nil)
        #expect(sut.containerWidth == nil)
        #expect(!sut.isOpen)
    }

    @Test(arguments: [900, 901, 1280, 4000] as [CGFloat])
    func givenAWidthAtOrAboveTheThreshold_whenMeasured_thenTheModeIsSplit(width: CGFloat) {
        // given
        let (sut, _) = make()

        // when
        sut.updateContainerWidth(width)

        // then
        #expect(sut.mode == .split)
    }

    @Test(arguments: [0, 1, 620, 899, 899.4] as [CGFloat])
    func givenAWidthBelowTheThreshold_whenMeasured_thenTheModeIsOverlay(width: CGFloat) {
        // given
        let (sut, _) = make()

        // when
        sut.updateContainerWidth(width)

        // then
        #expect(sut.mode == .overlay)
    }

    @Test func givenAMeasuredWidthBelowTheBreakpoint_whenAWidthWithinHalfAPointReachesIt_thenTheModeFlipsToSplit() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(899.8)
        #expect(sut.mode == .overlay)

        // when — 0.2 away, inside the tolerance, but on the other side of the breakpoint
        sut.updateContainerWidth(900)

        // then — the mode follows every measurement; the stored width stays the first one
        #expect(sut.mode == .split)
        #expect(sut.containerWidth == 899.8)
    }

    @Test func givenAMeasuredWidthAtTheBreakpoint_whenAWidthWithinHalfAPointFallsBelowIt_thenTheModeFlipsToOverlay() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(900)
        #expect(sut.mode == .split)

        // when
        sut.updateContainerWidth(899.6)

        // then
        #expect(sut.mode == .overlay)
        #expect(sut.containerWidth == 900)
    }

    @Test func givenAMeasuredWidth_whenAChangeWithinHalfAPointStaysOnTheSameSide_thenNeitherModeNorDefaultIsWritten() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(1000)
        sut.updateDefaultInput(Self.closedDefault)
        let tracker = Tracker {
            _ = sut.mode
            _ = store.appliedDefault(for: Self.conversation)
        }

        // when
        sut.updateContainerWidth(1000.3)
        sut.updateContainerWidth(999.8)

        // then
        #expect(tracker.fired == 0)
        #expect(sut.containerWidth == 1000)
        #expect(sut.mode == .split)
        #expect(store.appliedDefault(for: Self.conversation) == false)
    }

    @Test func givenAWidthChangeBeyondHalfAPoint_whenOnTheSameSide_thenTheWidthIsStoredAndTheModeIsNotRewritten() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1000)
        let tracker = Tracker { _ = sut.mode }

        // when
        sut.updateContainerWidth(1001)

        // then
        #expect(sut.containerWidth == 1001)
        #expect(tracker.fired == 0)
    }

    @Test func givenAResize_whenOnlyCrossingTheThresholdChangesTheMode_thenModeIsWrittenOnlyOnCrossings() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1000)
        let tracker = Tracker { _ = sut.mode }

        // when — widths on one side of the threshold
        for width in stride(from: 1000.0, through: 1600.0, by: 37.0) { sut.updateContainerWidth(width) }
        for width in stride(from: 1600.0, through: 900.0, by: -41.0) { sut.updateContainerWidth(width) }

        // then
        #expect(tracker.fired == 0)
        #expect(sut.mode == .split)

        // when — one crossing down, a drift below, one crossing up
        sut.updateContainerWidth(899)
        sut.updateContainerWidth(700)
        sut.updateContainerWidth(300)
        sut.updateContainerWidth(900)

        // then
        #expect(tracker.fired == 2)
        #expect(sut.mode == .split)
    }

    @Test func givenTheContainerWidth_whenItChanges_thenItIsNeverObserved() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1000)
        let tracker = Tracker { _ = sut.containerWidth }

        // when
        sut.updateContainerWidth(1100)
        sut.updateContainerWidth(950)

        // then
        #expect(tracker.fired == 0)
        #expect(sut.containerWidth == 950)
    }

    // MARK: - Default

    @Test func givenAWidthAndAReadyInput_whenResolved_thenTheDefaultIsAppliedOnceAndPersisted() {
        // given
        let (sut, store) = make()
        #expect(sut.appliedDefaultOpen == nil)

        // when
        sut.updateContainerWidth(1000)
        sut.updateDefaultInput(Self.opensAtSplit)

        // then
        #expect(sut.appliedDefaultOpen == true)
        #expect(store.appliedDefault(for: Self.conversation) == true)

        // when — later evidence never rewrites it
        sut.updateDefaultInput(Self.closedDefault)
        sut.updateContainerWidth(500)

        // then
        #expect(sut.appliedDefaultOpen == true)
        #expect(store.appliedDefault(for: Self.conversation) == true)
    }

    @Test func givenAnInputThatIsNotReady_whenWidthIsKnown_thenNothingIsResolvedUntilItIs() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(1000)

        // when
        sut.updateDefaultInput(.init())

        // then
        #expect(sut.appliedDefaultOpen == nil)
        #expect(store.appliedDefault(for: Self.conversation) == nil)
        #expect(!sut.isOpen)

        // when
        sut.updateDefaultInput(Self.opensAtSplit)

        // then
        #expect(sut.appliedDefaultOpen == true)
        #expect(sut.isOpen)
    }

    @Test func givenAReadyInputAndNoWidth_whenResolved_thenTheDefaultWaitsForTheFirstMeasurement() {
        // given
        let (sut, store) = make()

        // when
        sut.updateDefaultInput(Self.opensAtSplit)

        // then
        #expect(sut.appliedDefaultOpen == nil)
        #expect(store.appliedDefault(for: Self.conversation) == nil)

        // when
        sut.updateContainerWidth(800)

        // then — resolved at overlay width, which still stores the default
        #expect(sut.appliedDefaultOpen == true)
        #expect(!sut.isOpen)
    }

    @Test func givenAClosedDefault_whenRevisitedByANewControllerAfterTheTaskFinished_thenItStaysClosed() {
        // given
        let (first, store) = make()
        first.updateContainerWidth(1280)
        first.updateDefaultInput(Self.closedDefault)

        // when — a new view for the same conversation, now with a done task's evidence
        let revisit = Controller(store: store, conversationID: Self.conversation)
        revisit.updateContainerWidth(1280)
        revisit.updateDefaultInput(Self.opensAtSplit)

        // then
        #expect(revisit.appliedDefaultOpen == false)
        #expect(!revisit.isOpen)
    }

    @Test func givenAnEvictedStoreEntry_whenStillShown_thenTheLocalFallbackKeepsTheDefault() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(1280)
        sut.updateDefaultInput(Self.opensAtSplit)
        for index in 0 ..< TaskPaneStateStore.capacity { store.setOpenChoice(.open, for: "other\(index)") }
        #expect(store.appliedDefault(for: Self.conversation) == nil)

        // when
        sut.updateDefaultInput(Self.closedDefault)

        // then — neither re-derived from `noChoice` nor lost
        #expect(sut.appliedDefaultOpen == true)
        #expect(sut.isOpen)
        #expect(store.appliedDefault(for: Self.conversation) == nil)
    }

    @Test func givenTwoConversations_whenEachResolvesItsDefault_thenTheyAreIndependent() {
        // given
        let store = TaskPaneStateStore()
        let (first, _) = make(id: "A", store: store)
        let (second, _) = make(id: "B", store: store)

        // when
        first.updateContainerWidth(1280)
        first.updateDefaultInput(Self.opensAtSplit)
        second.updateContainerWidth(1280)
        second.updateDefaultInput(Self.closedDefault)

        // then
        #expect(first.isOpen)
        #expect(!second.isOpen)
    }

    // MARK: - isOpen

    @Test func givenADefaultOpenPane_whenTheWidthCrossesBelowAndBackAtTheThreshold_thenItClosesAndReopens() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1000)
        sut.updateDefaultInput(Self.opensAtSplit)
        #expect(sut.isOpen)

        // when / then
        sut.updateContainerWidth(899)
        #expect(!sut.isOpen)
        sut.updateContainerWidth(900)
        #expect(sut.isOpen)
        sut.updateContainerWidth(1500)
        #expect(sut.isOpen)
    }

    @Test(arguments: [500, 899, 900, 1600] as [CGFloat])
    func givenAPaneThePersonOpened_whenTheWidthChanges_thenItStaysOpenAtAnyWidth(width: CGFloat) {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1000)
        sut.updateDefaultInput(Self.closedDefault)
        sut.open()

        // when
        sut.updateContainerWidth(width + 100)
        sut.updateContainerWidth(width)

        // then
        #expect(sut.isOpen)
    }

    @Test func givenAPaneThePersonClosed_whenTheDefaultWouldOpenIt_thenItStaysClosed() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1280)
        sut.updateDefaultInput(Self.opensAtSplit)

        // when
        sut.close()

        // then
        #expect(!sut.isOpen)
        sut.updateContainerWidth(1600)
        #expect(!sut.isOpen)
    }

    @Test func givenNoChoiceAndNoDefault_whenToggled_thenItOpensAndThenCloses() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(1000)
        sut.updateDefaultInput(Self.closedDefault)

        // when / then
        sut.toggle()
        #expect(sut.isOpen)
        #expect(store.openChoice(for: Self.conversation) == .open)
        sut.toggle()
        #expect(!sut.isOpen)
        #expect(store.openChoice(for: Self.conversation) == .closed)
    }

    @Test func givenADefaultOpenPane_whenToggled_thenTheCloseIsStoredAsAChoice() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(1000)
        sut.updateDefaultInput(Self.opensAtSplit)

        // when
        sut.toggle()

        // then
        #expect(store.openChoice(for: Self.conversation) == .closed)
        #expect(!sut.isOpen)
    }

    // MARK: - Tabs and groups

    @Test func givenTheStoreDefaultTab_whenRead_thenChangesResolvesToEvents() {
        // given
        let (sut, store) = make()

        // when / then
        #expect(store.selectedTab(for: Self.conversation) == .changes)
        #expect(sut.selectedTab == .events)
    }

    @Test func givenAStoredChangesTab_whenRead_thenItStillResolvesToEvents() {
        // given
        let (sut, store) = make()
        store.setSelectedTab(.artifacts, for: Self.conversation)
        store.setSelectedTab(.changes, for: Self.conversation)

        // when / then
        #expect(sut.selectedTab == .events)
    }

    @Test func givenTheVisibleTabs_whenListed_thenChangesIsNotAmongThem() {
        // given / when / then
        #expect(Controller.visibleTabs == [.artifacts, .events])
    }

    @Test func givenAChangesSelection_whenSelected_thenItIsIgnoredAndOpensNothing() {
        // given
        let (sut, store) = make()

        // when
        sut.select(.changes)

        // then
        #expect(!sut.isOpen)
        #expect(!store.hasEntry(for: Self.conversation))
    }

    @Test func givenAVisibleTab_whenSelected_thenItIsStoredAndThePaneOpens() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(500)

        // when
        sut.select(.artifacts)

        // then
        #expect(sut.selectedTab == .artifacts)
        #expect(sut.isOpen)
        #expect(store.openChoice(for: Self.conversation) == .open)
    }

    @Test func givenGroupsAndTechnicalInfo_whenSet_thenTheyPersistInTheStore() {
        // given
        let (sut, store) = make()

        // when
        sut.setGroup(.task, expanded: true)
        sut.setGroup(.notices, expanded: true)
        sut.setGroup(.task, expanded: false)
        sut.setTechnicalInfoExpanded(true)
        sut.recordEventsScrollOffset(240)

        // then
        #expect(sut.expandedGroups == [.notices])
        #expect(store.expandedGroups(for: Self.conversation) == [.notices])
        #expect(sut.technicalInfoExpanded)
        #expect(sut.eventsScrollOffset == 240)
    }

    @Test func givenTheController_whenTouched_thenTheConversationBecomesMostRecent() {
        // given
        let store = TaskPaneStateStore()
        let (sut, _) = make(id: "A", store: store)
        store.setOpenChoice(.open, for: "A")
        store.setOpenChoice(.open, for: "B")

        // when
        sut.touch()

        // then
        #expect(store.rememberedIDs == ["B", "A"])
    }

    // MARK: - Animation helper

    @Test(arguments: [true, false])
    func givenAChange_whenRunThroughAnimated_thenItRunsOnceAndReturnsItsResult(reducesMotion: Bool) {
        // given
        let (sut, _) = make()
        sut.reducesMotion = reducesMotion
        var runs = 0

        // when
        let result = sut.animated { () -> Int in runs += 1; return 7 }

        // then
        #expect(runs == 1)
        #expect(result == 7)
    }
}
