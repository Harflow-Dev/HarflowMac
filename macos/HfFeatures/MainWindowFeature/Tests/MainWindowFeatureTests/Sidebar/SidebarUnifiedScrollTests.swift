import HfCommon
import HfRepository
import HfUI
@testable import MainWindowFeature
import Testing

/// The M04 unified scroll (`.hd-m04-sidebar-scroll`) is one flatten: navigation, Running, Recent
/// work and the history diagnostics under exactly one sentinel, with real destinations so native
/// selection drives shouldSelect, keyboard and highlights through a single path.
struct SidebarUnifiedScrollTests {
    @Test func givenUnifiedRole_whenFlattened_thenNavigationPrecedesRunningRecentHistoryAndOneSentinel() {
        // given
        var input = presentation(role: .unified)
        input.sections = [
            SidebarSection(bucket: .running, items: [
                .task(row("run-a", indent: 0)),
                .task(row("run-b", indent: 0))
            ]),
            SidebarSection(bucket: .today, items: [.task(row("today-a", indent: 0))]),
            SidebarSection(bucket: .earlier, items: [
                .task(row("root", indent: 0)),
                .task(row("child", indent: 1))
            ])
        ]
        // when
        let entries = SidebarListReconciler.reconcile(input, previous: []).entries
        let ids = entries.map(\.id)
        // then
        #expect(Array(ids.prefix(5)) == ["navigation:new-task", "navigation:needs-you", "navigation:workflows",
                                        "navigation:resources", "navigation:statistics"])
        #expect(entries.filter(\.isHeading).map(\.content) == [.heading("Running"), .heading("Recent work")])
        #expect(ids.firstIndex(of: "header:running") == 5)
        #expect(ids.firstIndex(of: "task:run-a") == 6)
        #expect(ids.firstIndex(of: "header:recent") == 8)
        #expect(ids.firstIndex(of: "task:today-a") == 9)
        #expect(ids.firstIndex(of: "task:root") == 10)
        #expect(entries.last?.content == .sentinel)
        #expect(entries.filter { $0.content == .sentinel }.count == 1)
        #expect(!ids.contains { $0.hasPrefix("overview:") || $0.hasPrefix("definition:") || $0 == "header:workflows" })
        #expect(!ids.contains("header:today") && !ids.contains("header:earlier"))
    }

    @Test func givenUnifiedRole_whenFlattened_thenNavigationTitlesArtworkDestinationsBadgeAndShortcutStayTyped() {
        // given
        var input = presentation(role: .unified)
        input.needsYouBadge = .count(3, atLeast: false)
        // when
        let entries = SidebarListReconciler.reconcile(input, previous: []).entries
        let navigation = entries.prefix(5).map { entry -> SidebarNavigationEntry? in
            guard case .navigation(let navigation) = entry.content else { return nil }
            return navigation
        }
        // then
        #expect(navigation.compactMap(\.self).count == 5)
        let typed = navigation.compactMap(\.self)
        #expect(typed.map(\.title) == ["New task", "Needs you", "Workflows", "Resources", "Statistics"])
        #expect(typed.map(\.artwork) == [.plus, .hand, .workflow, .gauge, .chart])
        #expect(typed.map(\.badge.capsuleText) == [nil, "3", nil, nil, nil])
        #expect(typed.map(\.shortcut) == ["⌘N", nil, nil, nil, nil])
        #expect(entries.prefix(5).enumerated().allSatisfy { index, entry in
            entry.destination == typed[index].destination
        })
        #expect(typed.map(\.destination) == [.newSession, .needsYou(itemID: nil), .workflowLibrary, .resourceSlots, .statistics])
        if case .navigation(let needsYou) = entries[1].content {
            #expect(needsYou.badge.accessibilityLabel == "Needs you, 3 pending")
        }
    }

    @Test func givenUnifiedRole_whenPresentedAfterRecent_thenTaskIdentitySurvivesTheSingleFlatten() {
        // given
        var input = presentation(role: .unified)
        input.sections = [
            SidebarSection(bucket: .running, items: [.task(row("run-a", indent: 0))]),
            SidebarSection(bucket: .today, items: [.task(row("root", indent: 0)), .task(row("child", indent: 1))]),
            SidebarSection(bucket: .earlier, items: [.task(row("earlier", indent: 0))])
        ]
        var recent = input
        recent.role = .recent
        recent.sections = Array(input.sections.filter { $0.bucket != .running })
        // when — both surfaces are filtered to the same retained Recent work ids: unified also
        // carries the Running item, so an unfiltered comparison could never match.
        let retainedRecentIDs = ["task:root", "task:child", "task:earlier"]
        let recentEntries = SidebarListReconciler.reconcile(recent, previous: []).entries
        let unifiedEntries = SidebarListReconciler.reconcile(input, previous: []).entries
        let recentItems = recentEntries.filter { retainedRecentIDs.contains($0.id) }
        let unifiedItems = unifiedEntries.filter { retainedRecentIDs.contains($0.id) }
        // then — one occurrence scope spans the unified halves, so display identities never collide.
        #expect(unifiedItems.map(\.displayID) == recentItems.map(\.displayID))
        #expect(unifiedItems.map(\.destination) == recentItems.map(\.destination))
        if let child = unifiedItems.first(where: { $0.id == "task:child" }) {
            #expect(child.displayID.ownerID == "task:root")
        }
    }

    @Test func givenUnifiedSkeleton_whenFlattened_thenNavigationStaysAndHistoryWaitsForContent() {
        // given
        var input = presentation(role: .unified)
        input.skeleton = true
        input.sections = [SidebarSection(bucket: .running, items: [.task(row("run-a", indent: 0))])]
        // when
        let entries = SidebarListReconciler.reconcile(input, previous: []).entries
        // then — the skeleton replaces content and history, including the sentinel.
        #expect(entries.map(\.id) == ["navigation:new-task", "navigation:needs-you", "navigation:workflows",
                                       "navigation:resources", "navigation:statistics", "diagnostic:skeleton"])
        #expect(!entries.contains { $0.content == .sentinel })
    }

    private func row(_ id: String, indent: Int) -> TaskRowModel {
        TaskRowModel(id: id, backend: "codex", title: id, status: .running,
                     repoName: "fixture", ageText: "1m", indent: indent)
    }

    private func presentation(role: SidebarListPresentation.Role) -> SidebarListPresentation {
        SidebarListPresentation(sections: [], workflowTitles: ["Retained definition"], workflowsExpanded: true,
                                banner: nil, listError: nil, skeleton: false,
                                taskHistory: HistoryLoadingState(), workflowHistory: HistoryLoadingState(),
                                emptyMessage: nil, fadingIDs: [], minimumRowHeight: 0,
                                historyRevision: 0, historyToken: "unified", role: role)
    }
}
