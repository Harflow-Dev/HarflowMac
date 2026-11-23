import HfCommon
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

/// The refresh note's trigger and its place in the unified list.
struct SidebarRefreshNoteTests {
    static let timedOut = ToolError.timedOut(tool: "harflow-ctl task-list-page", seconds: 30)
    static let unreadable = ToolError.unreadable(tool: "harflow-ctl task-list-page", exitCode: 1, stderr: "")

    @Test func givenTheDrawnCopy_whenRead_thenItIsVerbatim() {
        // given / when / then
        #expect(SidebarRefreshNote.title == "Couldn't refresh your work")
        #expect(SidebarRefreshNote.retryTitle == "Retry")
    }

    @Test(arguments: [
        (false, nil, false), (true, nil, false), (false, SidebarRefreshNoteTests.timedOut, false), (true, SidebarRefreshNoteTests.timedOut, true),
        (true, SidebarRefreshNoteTests.unreadable, true),
        (true, ToolError.notFound(tool: "harflow-ctl", searched: []), true),
        (true, ToolError.unsupportedVersion(tool: "harflow-ctl", version: "2"), false),
        (true, ToolError.refused(code: "managed_runtime_failed", message: "Failed."), false)
    ] as [(Bool, ToolError?, Bool)])
    func givenAListingState_whenClassified_thenTheNoteShowsOnlyAfterTheFirstListingForUnownedErrors(
        hasListed: Bool, error: ToolError?, expected: Bool
    ) {
        // given / when
        let shows = SidebarRefreshNote.shows(hasListed: hasListed, listError: error)
        // then
        #expect(shows == expected)
    }

    @Test func givenTheNote_whenFlattenedInTheUnifiedRole_thenItFollowsNavigationAndPrecedesRunning() {
        // given
        var input = presentation()
        input.refreshFailed = true
        // when
        let ids = SidebarListReconciler.reconcile(input, previous: []).entries.map(\.id)
        // then
        #expect(ids.firstIndex(of: "diagnostic:refresh-failed") == 6)
        #expect(ids.firstIndex(of: "header:running") == 7)
        #expect(ids.filter { $0 == "diagnostic:refresh-failed" }.count == 1)
    }

    @Test func givenTheNote_whenCleared_thenOnlyTheNoteIdentityChanges() {
        // given
        var input = presentation()
        input.refreshFailed = true
        let shown = SidebarListReconciler.reconcile(input, previous: [])
        input.refreshFailed = false
        // when
        let cleared = SidebarListReconciler.reconcile(input, previous: shown.entries)
        // then
        #expect(!cleared.entries.contains { $0.id == "diagnostic:refresh-failed" })
        #expect(cleared.changedIDs.isEmpty || cleared.changedIDs.allSatisfy { $0.logicalID != "diagnostic:refresh-failed" })
        #expect(cleared.entries.count == shown.entries.count - 1)
    }

    @Test func givenAFixtureRole_whenFlattenedWithTheNote_thenNoNoteRowShows() {
        // given
        var input = presentation()
        input.role = .combined
        input.refreshFailed = true
        // when
        let ids = SidebarListReconciler.reconcile(input, previous: []).entries.map(\.id)
        // then
        #expect(!ids.contains("diagnostic:refresh-failed"))
    }

    private func presentation() -> SidebarListPresentation {
        SidebarListPresentation(sections: [], workflowTitles: [], workflowsExpanded: false,
                                listError: nil, skeleton: false,
                                taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(),
                                emptyMessage: nil, fadingIDs: [], minimumRowHeight: 0,
                                historyRevision: 0, historyToken: "note", role: .unified)
    }
}
