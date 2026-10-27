import Foundation
import HfCommon
import HfRepository
import HfUI
@testable import MainWindowFeature
import MonitorCore
import Testing

@MainActor
@Suite struct StatisticsNavigationTests {
    @Test func givenSidebarReconciliation_whenBuilt_thenStatisticsHasOverviewDestination() throws {
        // given
        let input = SidebarListPresentation(
            sections: [], workflowTitles: [], workflowsExpanded: true, banner: nil,
            listError: nil, skeleton: false, taskHistory: HistoryLoadingState(),
            workflowHistory: HistoryLoadingState(), emptyMessage: nil, fadingIDs: [],
            minimumRowHeight: 0, historyRevision: 0, historyToken: "token"
        )

        // when
        let result = try #require(SidebarListReconciler.reconcile(input, previousInput: nil, previous: [], overlay: [:]))
        let entry = try #require(result.entries.first { $0.id == "overview:statistics" })
        let index = try #require(result.entries.firstIndex(of: entry))

        // then
        #expect(result.entries.first?.content == .heading("Overview"))
        #expect(entry.content == .statistics)
        #expect(entry.destination == .statistics)
        #expect(result.destinations[.statistics]?.contains(index) == true)
    }
}
