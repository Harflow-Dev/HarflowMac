//
//  TaskPaneStateStoreTests.swift
//  MainWindowFeatureTests
//

import Foundation
@testable import MainWindowFeature
import Observation
import Testing

// MARK: - TaskPaneStateStoreTests

@MainActor
struct TaskPaneStateStoreTests {
    private typealias Store = TaskPaneStateStore

    /// Counts Observation notifications of reads of one conversation, re-arming after each.
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

    // MARK: - Defaults

    @Test func givenAnEmptyStore_whenReadingAnyConversation_thenDefaultsAreReturned() {
        // given
        let sut = Store()

        // when / then
        #expect(sut.openChoice(for: "a") == .noChoice)
        #expect(sut.selectedTab(for: "a") == nil)
        #expect(sut.appliedDefaultTab(for: "a") == nil)
        #expect(sut.expandedGroups(for: "a").isEmpty)
        #expect(!sut.hasEntry(for: "a"))
        #expect(sut.rememberedIDs.isEmpty)
    }

    @Test func givenTheCapacity_whenRead_thenItIsSixtyFour() {
        // given / when / then
        #expect(Store.capacity == 64)
    }

    // MARK: - Writing

    @Test func givenAChangedValue_whenWriting_thenItIsStoredPerConversation() {
        // given
        let sut = Store()

        // when
        sut.setOpenChoice(.open, for: "a")
        sut.setSelectedTab(.events, for: "a")
        sut.setGroup(.task, expanded: true, for: "a")
        sut.setGroup(.usage, expanded: true, for: "a")
        sut.setGroup(.task, expanded: false, for: "a")

        // then
        #expect(sut.openChoice(for: "a") == .open)
        #expect(sut.selectedTab(for: "a") == .events)
        #expect(sut.expandedGroups(for: "a") == [.usage])
        #expect(sut.hasEntry(for: "a"))
        #expect(sut.openChoice(for: "b") == .noChoice)
        #expect(!sut.hasEntry(for: "b"))
    }

    @Test func givenTheTriState_whenSettingEachValue_thenNoChoiceOpenAndClosedStayDistinct() {
        // given
        let sut = Store()

        // when / then
        sut.setOpenChoice(.closed, for: "a")
        #expect(sut.openChoice(for: "a") == .closed)
        sut.setOpenChoice(.open, for: "a")
        #expect(sut.openChoice(for: "a") == .open)
        sut.setOpenChoice(.noChoice, for: "a")
        #expect(sut.openChoice(for: "a") == .noChoice)
        #expect(sut.hasEntry(for: "a"))
    }

    @Test func givenEveryTab_whenSelected_thenEachIsStored() {
        // given
        let sut = Store()

        // when / then
        for tab in Store.Tab.allCases {
            sut.setSelectedTab(tab, for: "a")
            #expect(sut.selectedTab(for: "a") == tab)
        }
    }

    @Test func givenADefaultValuedWrite_whenTheConversationIsUnknown_thenNothingIsCreated() {
        // given
        let sut = Store()

        // when
        sut.setOpenChoice(.noChoice, for: "a")
        sut.setExpandedGroups([], for: "a")
        sut.setGroup(.task, expanded: false, for: "a")

        // then
        #expect(!sut.hasEntry(for: "a"))
        #expect(sut.rememberedIDs.isEmpty)
    }

    // MARK: - Observation

    @Test func givenAnEqualValue_whenWriting_thenNoObservationNotificationFires() {
        // given
        let sut = Store()
        sut.setOpenChoice(.open, for: "a")
        sut.setSelectedTab(.events, for: "a")
        sut.setExpandedGroups([.task], for: "a")
        let tracker = Tracker {
            _ = sut.openChoice(for: "a")
            _ = sut.selectedTab(for: "a")
            _ = sut.expandedGroups(for: "a")
            _ = sut.hasEntry(for: "a")
        }

        // when
        sut.setOpenChoice(.open, for: "a")
        sut.setSelectedTab(.events, for: "a")
        sut.setExpandedGroups([.task], for: "a")
        sut.setGroup(.task, expanded: true, for: "a")
        sut.setGroup(.notices, expanded: false, for: "a")

        // then
        #expect(tracker.fired == 0)
    }

    @Test func givenAChangedValue_whenWriting_thenExactlyOneNotificationFires() {
        // given
        let sut = Store()
        let tracker = Tracker { _ = sut.openChoice(for: "a") }

        // when
        sut.setOpenChoice(.open, for: "a")

        // then
        #expect(tracker.fired == 1)
    }

    @Test func givenAChangedValue_whenWritingTwiceWithTheSameValue_thenOnlyTheFirstNotifies() {
        // given
        let sut = Store()
        let tracker = Tracker { _ = sut.selectedTab(for: "a") }

        // when
        sut.setSelectedTab(.artifacts, for: "a")
        sut.setSelectedTab(.artifacts, for: "a")

        // then
        #expect(tracker.fired == 1)
    }

    @Test func givenADefaultValuedWriteToAnUnknownConversation_whenObserving_thenNoNotificationFires() {
        // given
        let sut = Store()
        let tracker = Tracker { _ = sut.openChoice(for: "a") }

        // when
        sut.setOpenChoice(.noChoice, for: "a")

        // then
        #expect(tracker.fired == 0)
    }

    // MARK: - Recency

    @Test func givenWrites_whenListingRememberedIDs_thenLeastRecentlyUsedComesFirst() {
        // given
        let sut = Store()

        // when
        sut.setOpenChoice(.open, for: "a")
        sut.setOpenChoice(.open, for: "b")
        sut.setOpenChoice(.open, for: "c")

        // then
        #expect(sut.rememberedIDs == ["a", "b", "c"])
    }

    @Test func givenAnEqualWrite_whenWriting_thenTheConversationIsStillTouched() {
        // given
        let sut = Store()
        sut.setOpenChoice(.open, for: "a")
        sut.setOpenChoice(.open, for: "b")

        // when
        sut.setOpenChoice(.open, for: "a")

        // then
        #expect(sut.rememberedIDs == ["b", "a"])
    }

    @Test func givenAnEntry_whenTouched_thenItMovesLastWithoutNotifying() {
        // given
        let sut = Store()
        sut.setOpenChoice(.open, for: "a")
        sut.setOpenChoice(.open, for: "b")
        let tracker = Tracker {
            _ = sut.openChoice(for: "a")
            _ = sut.openChoice(for: "b")
            _ = sut.hasEntry(for: "a")
            _ = sut.rememberedIDs
        }

        // when
        sut.touch("a")

        // then
        #expect(sut.rememberedIDs == ["b", "a"])
        #expect(tracker.fired == 0)
    }

    @Test func givenTheMostRecentEntry_whenTouched_thenOrderIsUnchanged() {
        // given
        let sut = Store()
        sut.setOpenChoice(.open, for: "a")
        sut.setOpenChoice(.open, for: "b")

        // when
        sut.touch("b")

        // then
        #expect(sut.rememberedIDs == ["a", "b"])
    }

    @Test func givenAnUnknownConversation_whenTouched_thenNothingChanges() {
        // given
        let sut = Store()
        sut.setOpenChoice(.open, for: "a")

        // when
        sut.touch("missing")

        // then
        #expect(sut.rememberedIDs == ["a"])
        #expect(!sut.hasEntry(for: "missing"))
    }

    // MARK: - Eviction

    @Test func givenTheStoreAtCapacity_whenAddingASixtyFifthEntry_thenTheLeastRecentlyUsedIsEvicted() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setOpenChoice(.open, for: "id\(index)") }
        #expect(sut.rememberedIDs.count == 64)

        // when
        sut.setOpenChoice(.closed, for: "new")

        // then
        #expect(sut.rememberedIDs.count == 64)
        #expect(!sut.hasEntry(for: "id0"))
        #expect(sut.openChoice(for: "id0") == .noChoice)
        #expect(sut.hasEntry(for: "id1"))
        #expect(sut.openChoice(for: "new") == .closed)
        #expect(sut.rememberedIDs.last == "new")
    }

    @Test func givenATouchedOldestEntry_whenAddingASixtyFifthEntry_thenTheNextOldestIsEvicted() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setOpenChoice(.open, for: "id\(index)") }
        sut.touch("id0")

        // when
        sut.setOpenChoice(.closed, for: "new")

        // then
        #expect(sut.hasEntry(for: "id0"))
        #expect(!sut.hasEntry(for: "id1"))
        #expect(sut.hasEntry(for: "new"))
    }

    @Test func givenAnEqualWriteToTheOldestEntry_whenAddingASixtyFifthEntry_thenItSurvives() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setOpenChoice(.open, for: "id\(index)") }
        sut.setOpenChoice(.open, for: "id0")

        // when
        sut.setOpenChoice(.closed, for: "new")

        // then
        #expect(sut.hasEntry(for: "id0"))
        #expect(!sut.hasEntry(for: "id1"))
    }

    @Test func givenTheStoreAtCapacity_whenWritingTheDefaultToAnUnknownConversation_thenNothingIsEvicted() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setOpenChoice(.open, for: "id\(index)") }

        // when
        sut.setOpenChoice(.noChoice, for: "unknown")

        // then
        #expect(sut.rememberedIDs.count == 64)
        #expect(sut.hasEntry(for: "id0"))
        #expect(!sut.hasEntry(for: "unknown"))
    }

    @Test func givenTheStoreAtCapacity_whenChangingAnExistingEntry_thenNothingIsEvicted() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setOpenChoice(.open, for: "id\(index)") }

        // when
        sut.setSelectedTab(.events, for: "id0")

        // then
        #expect(sut.rememberedIDs.count == 64)
        #expect(sut.rememberedIDs.last == "id0")
        #expect(sut.hasEntry(for: "id1"))
        #expect(sut.selectedTab(for: "id0") == .events)
    }

    @Test func givenManyWritesPastCapacity_whenEvicting_thenTheJustWrittenEntryIsNeverRemoved() {
        // given
        let sut = Store()

        // when
        for index in 0 ..< (Store.capacity * 2) {
            sut.setOpenChoice(.open, for: "id\(index)")

            // then
            #expect(sut.hasEntry(for: "id\(index)"))
            #expect(sut.rememberedIDs.count <= Store.capacity)
        }
        #expect(sut.rememberedIDs.first == "id64")
    }

    // MARK: - Applied default

    @Test func givenAnEmptyStore_whenReadingTheAppliedDefault_thenItIsNil() {
        // given
        let sut = Store()

        // when / then
        #expect(sut.appliedDefault(for: "a") == nil)
    }

    @Test func givenAClosedDefault_whenWritten_thenAnEntryRemembersItDistinctFromNone() {
        // given
        let sut = Store()

        // when
        sut.setAppliedDefault(false, for: "a")

        // then
        #expect(sut.appliedDefault(for: "a") == false)
        #expect(sut.hasEntry(for: "a"))
        #expect(sut.openChoice(for: "a") == .noChoice)
    }

    @Test func givenAnAppliedDefault_whenWritten_thenItIsPerConversationAndNotifiesOnlyOnChange() {
        // given
        let sut = Store()
        let tracker = Tracker { _ = sut.appliedDefault(for: "a") }

        // when
        sut.setAppliedDefault(true, for: "a")
        sut.setAppliedDefault(true, for: "a")

        // then
        #expect(tracker.fired == 1)
        #expect(sut.appliedDefault(for: "a") == true)
        #expect(sut.appliedDefault(for: "b") == nil)
    }

    @Test func givenTheAppliedDefault_whenTheEntryIsEvicted_thenItReadsNilAgain() {
        // given
        let sut = Store()
        sut.setAppliedDefault(true, for: "a")

        // when
        for index in 0 ..< Store.capacity { sut.setOpenChoice(.open, for: "id\(index)") }

        // then
        #expect(sut.appliedDefault(for: "a") == nil)
    }

    // MARK: - Technical info

    @Test func givenAnEmptyStore_whenReadingTechnicalInfo_thenItIsCollapsed() {
        // given
        let sut = Store()

        // when / then
        #expect(!sut.technicalInfoExpanded(for: "a"))
    }

    @Test func givenTechnicalInfo_whenExpandedAndCollapsed_thenItPersistsAndEqualWritesAreQuiet() {
        // given
        let sut = Store()
        let tracker = Tracker { _ = sut.technicalInfoExpanded(for: "a") }

        // when
        sut.setTechnicalInfoExpanded(true, for: "a")
        sut.setTechnicalInfoExpanded(true, for: "a")

        // then
        #expect(sut.technicalInfoExpanded(for: "a"))
        #expect(!sut.technicalInfoExpanded(for: "b"))
        #expect(tracker.fired == 1)

        // when
        sut.setTechnicalInfoExpanded(false, for: "a")

        // then
        #expect(!sut.technicalInfoExpanded(for: "a"))
    }

    @Test func givenACollapsedWriteToAnUnknownConversation_whenWriting_thenNoEntryIsCreated() {
        // given
        let sut = Store()

        // when
        sut.setTechnicalInfoExpanded(false, for: "a")

        // then
        #expect(!sut.hasEntry(for: "a"))
    }

    // MARK: - Events offsets

    @Test func givenAnEmptyStore_whenReadingAnOffset_thenItIsNil() {
        // given
        let sut = Store()

        // when / then
        #expect(sut.eventsScrollOffset(for: "a") == nil)
    }

    @Test func givenOffsets_whenWritten_thenEachConversationKeepsItsOwnAndZeroIsKept() {
        // given
        let sut = Store()

        // when
        sut.setEventsScrollOffset(120, for: "a")
        sut.setEventsScrollOffset(0, for: "b")
        sut.setEventsScrollOffset(240, for: "a")

        // then
        #expect(sut.eventsScrollOffset(for: "a") == 240)
        #expect(sut.eventsScrollOffset(for: "b") == 0)
    }

    @Test func givenAnOffsetWrite_whenObserved_thenNothingReadingEntriesRecencyOrChoicesIsInvalidated() {
        // given
        let sut = Store()
        sut.setOpenChoice(.open, for: "a")
        let tracker = Tracker {
            _ = sut.openChoice(for: "a")
            _ = sut.selectedTab(for: "a")
            _ = sut.expandedGroups(for: "a")
            _ = sut.hasEntry(for: "a")
            _ = sut.hasEntry(for: "b")
            _ = sut.appliedDefault(for: "a")
            _ = sut.technicalInfoExpanded(for: "a")
            _ = sut.eventsScrollOffset(for: "a")
        }

        // when
        sut.setEventsScrollOffset(10, for: "a")
        sut.setEventsScrollOffset(20, for: "b")
        sut.setEventsScrollOffset(30, for: "a")

        // then
        #expect(tracker.fired == 0)
    }

    @Test func givenAnOffsetWrite_whenForAnUnknownConversation_thenNoEntryOrRecencyIsCreated() {
        // given
        let sut = Store()
        sut.setOpenChoice(.open, for: "a")

        // when
        sut.setEventsScrollOffset(50, for: "b")

        // then
        #expect(!sut.hasEntry(for: "b"))
        #expect(sut.rememberedIDs == ["a"])
        #expect(sut.eventsScrollOffset(for: "b") == 50)
    }

    @Test func givenMoreOffsetsThanTheCapacity_whenWriting_thenTheLeastRecentlyWrittenIsDropped() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setEventsScrollOffset(CGFloat(index), for: "id\(index)") }
        #expect(sut.eventsScrollOffset(for: "id0") == 0)

        // when
        sut.setEventsScrollOffset(999, for: "new")

        // then
        #expect(sut.eventsScrollOffset(for: "id0") == nil)
        #expect(sut.eventsScrollOffset(for: "id1") == 1)
        #expect(sut.eventsScrollOffset(for: "new") == 999)
    }

    @Test func givenARewrittenOldestOffset_whenEvicting_thenItMovesToTheBackAndTheNextOldestGoes() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setEventsScrollOffset(CGFloat(index), for: "id\(index)") }

        // when
        sut.setEventsScrollOffset(500, for: "id0")
        sut.setEventsScrollOffset(1, for: "new")

        // then
        #expect(sut.eventsScrollOffset(for: "id0") == 500)
        #expect(sut.eventsScrollOffset(for: "id1") == nil)
        #expect(sut.eventsScrollOffset(for: "id2") == 2)
    }

    @Test func givenReads_whenEvictingOffsets_thenReadingDoesNotRefreshRecency() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setEventsScrollOffset(CGFloat(index), for: "id\(index)") }

        // when
        _ = sut.eventsScrollOffset(for: "id0")
        sut.setEventsScrollOffset(1, for: "new")

        // then
        #expect(sut.eventsScrollOffset(for: "id0") == nil)
    }

    @Test func givenTheSameOffsetKeyWrittenRepeatedly_whenAtCapacity_thenNothingIsEvicted() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setEventsScrollOffset(CGFloat(index), for: "id\(index)") }

        // when
        for value in 0 ..< 10 { sut.setEventsScrollOffset(CGFloat(value), for: "id63") }

        // then
        #expect(sut.eventsScrollOffset(for: "id0") == 0)
        #expect(sut.eventsScrollOffset(for: "id63") == 9)
    }

    @Test func givenManyOffsets_whenEvicting_thenEntriesRecencyAndChoicesAreUntouched() {
        // given
        let sut = Store()
        for index in 0 ..< Store.capacity { sut.setOpenChoice(.open, for: "id\(index)") }
        sut.setEventsScrollOffset(5, for: "id0")
        let remembered = sut.rememberedIDs

        // when — enough offsets for other conversations to evict id0's offset many times over
        for index in 0 ..< (Store.capacity * 2) { sut.setEventsScrollOffset(CGFloat(index), for: "offset\(index)") }

        // then
        #expect(sut.eventsScrollOffset(for: "id0") == nil)
        #expect(sut.rememberedIDs == remembered)
        for index in 0 ..< Store.capacity {
            #expect(sut.hasEntry(for: "id\(index)"))
            #expect(sut.openChoice(for: "id\(index)") == .open)
        }
    }

    @Test func givenAnEvictedEntry_whenItHadAnOffset_thenTheOffsetIsIndependentOfIt() {
        // given
        let sut = Store()
        sut.setOpenChoice(.open, for: "a")
        sut.setEventsScrollOffset(77, for: "a")

        // when
        for index in 0 ..< Store.capacity { sut.setOpenChoice(.open, for: "id\(index)") }

        // then
        #expect(!sut.hasEntry(for: "a"))
        #expect(sut.eventsScrollOffset(for: "a") == 77)
    }
}
