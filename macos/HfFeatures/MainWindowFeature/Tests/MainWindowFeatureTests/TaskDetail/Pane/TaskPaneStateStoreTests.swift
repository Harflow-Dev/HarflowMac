//
//  TaskPaneStateStoreTests.swift
//  MainWindowFeatureTests
//

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
        #expect(sut.selectedTab(for: "a") == .changes)
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
        sut.setSelectedTab(.changes, for: "a")
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
}
