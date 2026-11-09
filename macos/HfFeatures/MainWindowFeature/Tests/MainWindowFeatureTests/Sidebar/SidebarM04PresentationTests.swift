import HfRepository
import HfUI
@testable import MainWindowFeature
import MonitorCore
import Testing

struct SidebarM04PresentationTests {
    @Test func givenShellRoles_whenFlattened_thenNavigationIsExternalAndOnlyRecentOwnsHistory() {
        // given
        let running = presentation(role: .running)
        let recent = presentation(role: .recent)
        // when
        let runningEntries = SidebarListReconciler.reconcile(running, previous: []).entries
        let recentEntries = SidebarListReconciler.reconcile(recent, previous: []).entries
        // then
        for entries in [runningEntries, recentEntries] {
            #expect(!entries.contains { $0.id.hasPrefix("overview:") || $0.id == "header:workflows" || $0.id.hasPrefix("definition:") })
        }
        #expect(!runningEntries.contains { $0.id.hasPrefix("history:") || $0.id == "header:history" })
        #expect(recentEntries.contains { $0.id == "history:sentinel" })
        #expect(runningEntries.contains { $0.content == .heading("Running") })
    }

    @Test func givenTodayAndEarlierTrees_whenPresentedAsRecent_thenOneHeadingPreservesOwnerAndLogicalIdentity() {
        // given
        var input = presentation(role: .recent)
        let root = row("root", indent: 0)
        let child = row("child", indent: 1)
        let earlier = row("earlier", indent: 0)
        input.sections = [.init(bucket: .today, items: [.task(root), .task(child)]),
                          .init(bucket: .earlier, items: [.task(earlier)])]
        var combined = input
        combined.role = .combined
        // when
        let before = SidebarListReconciler.reconcile(combined, previous: []).entries
        let after = SidebarListReconciler.reconcile(input, previous: before).entries
        // then
        #expect(after.filter(\.isHeading).map(\.content) == [.heading("Recent work")])
        let beforeItems = before.filter { $0.id.hasPrefix("task:") }
        let afterItems = after.filter { $0.id.hasPrefix("task:") }
        #expect(afterItems.map(\.displayID) == beforeItems.map(\.displayID))
        #expect(afterItems.map(\.destination) == beforeItems.map(\.destination))
        #expect(afterItems[1].displayID.ownerID == "task:root")
        #expect(afterItems.map(\.content) == [.item(.task(root)), .item(.task(child)), .item(.task(earlier))])
    }

    private func row(_ id: String, indent: Int) -> TaskRowModel {
        TaskRowModel(id: id, backend: "codex", title: id, status: .running,
                     repoName: "fixture", ageText: "1m", indent: indent)
    }

    private func presentation(role: SidebarListPresentation.Role) -> SidebarListPresentation {
        SidebarListPresentation(sections: [], workflowTitles: ["Retained definition"], workflowsExpanded: true,
                                listError: nil, skeleton: false,
                                taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(),
                                emptyMessage: nil, fadingIDs: [], minimumRowHeight: 0,
                                historyRevision: 0, historyToken: "m04", role: role)
    }
}
