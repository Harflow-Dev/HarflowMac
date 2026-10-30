import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfUI
@testable import MainWindowFeature
import Mockable
import Testing

// MARK: - NeedsYouNavigationTests

@MainActor
@Suite struct NeedsYouNavigationTests {
    private func input(_ badge: NeedsYouBadge) -> SidebarListPresentation {
        SidebarListPresentation(
            sections: [], workflowTitles: [], workflowsExpanded: true, banner: nil, listError: nil, skeleton: false,
            taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(), emptyMessage: nil, fadingIDs: [],
            minimumRowHeight: 0, historyRevision: 0, historyToken: "token", needsYouBadge: badge
        )
    }

    @Test func givenSidebarReconciliation_whenBuilt_thenNeedsYouIsTheFirstOverviewRowBeforeStatistics() throws {
        // given / when
        let result = try #require(SidebarListReconciler.reconcile(input(.count(2, atLeast: false)), previousInput: nil, previous: [], overlay: [:]))
        // then
        #expect(result.entries.prefix(3).map(\.id) == ["header:overview", "overview:needs-you", "overview:statistics"])
        let entry = result.entries[1]
        #expect(entry.content == .needsYou(.count(2, atLeast: false)))
        #expect(entry.destination == .needsYou(itemID: nil))
        #expect(result.destinations[.needsYou(itemID: nil)]?.contains(1) == true)
    }

    @Test func givenBadgeChange_whenReconciled_thenOnlyTheNeedsYouRowChanges() throws {
        // given
        let first = try #require(SidebarListReconciler.reconcile(input(.none), previousInput: nil, previous: [], overlay: [:]))
        let second = try #require(SidebarListReconciler.reconcile(input(.count(1, atLeast: false)), previousInput: input(.none),
                                                                  previous: first.entries, overlay: [:]))
        // then
        #expect(second.changedIDs.map(\.logicalID) == ["overview:needs-you"])
        #expect(input(.none) != input(.count(1, atLeast: false)))
    }

    @Test func givenNeedsYouDestinations_whenHandled_thenSelectionKeepsTheItemID() {
        // given
        let parent = MockCoordinator()
        given(parent).handle(path: .any).willReturn()
        let sut = MainWindowCoordinator(parent: parent)
        // when
        sut.handle(path: MonitorDestination.needsYou(itemID: "input:w:d"))
        // then
        #expect(sut.selection == .needsYou(itemID: "input:w:d"))
        verify(parent).handle(path: .any).called(0)
        sut.showNeedsYou(itemID: nil)
        #expect(sut.selection == .needsYou(itemID: nil))
    }

    @Test func givenNeedsYouDestination_whenIdentified_thenPathIDsAreDistinct() {
        #expect(MonitorDestination.needsYou(itemID: nil).pathId == "needsYou:")
        #expect(MonitorDestination.needsYou(itemID: "input:a:b").pathId == "needsYou:input:a:b")
    }

    @Test func givenCoordinator_whenBuildingNeedsYou_thenAViewIsProduced() {
        let sut = MainWindowCoordinator(parent: MockCoordinator())
        _ = sut.buildNeedsYouView(itemID: nil)
        _ = sut.buildNeedsYouView(itemID: "input:a:b")
    }
}
