@testable import MainWindowFeature
import PbUI
import Testing

// MARK: - SidebarSectionTests

struct SidebarSectionTests {
    private func row(_ id: String) -> SidebarItem {
        .task(TaskRowModel(id: id, backend: "codex", title: id, status: .running, repoName: "repo", ageText: ""))
    }

    @Test func givenCollapsedChildren_whenRetainingOutgoingRows_thenTheirOrderStaysBetweenParents() {
        // given
        let old = [SidebarSection(bucket: .running, items: [row("parent"), row("child1"), row("child2"), row("next")])]
        let new = [SidebarSection(bucket: .running, items: [row("parent"), row("next")])]
        // when
        let retained = SidebarSection.retainingRemovedRows(from: old, in: new)
        // then
        #expect(retained[0].items.map(\.id) == old[0].items.map(\.id))
    }

    @Test func givenTaskMovingToAnotherBucket_whenRetainingOutgoingRows_thenItIsNotDuplicated() {
        // given
        let old = [SidebarSection(bucket: .running, items: [row("task")])]
        let new = [SidebarSection(bucket: .today, items: [row("task")])]
        // when
        let retained = SidebarSection.retainingRemovedRows(from: old, in: new)
        // then
        #expect(retained == new)
    }

    @Test func givenReExpansionBeforeRemoval_whenReconciling_thenCurrentRowsWinWithoutDuplicates() {
        // given
        let fading = [SidebarSection(bucket: .running, items: [row("parent"), row("child")])]
        let expanded = [SidebarSection(bucket: .running, items: [row("parent"), row("child"), row("new")])]
        // when
        let retained = SidebarSection.retainingRemovedRows(from: fading, in: expanded)
        // then
        #expect(retained == expanded)
    }

    @Test func givenRunningBucketDisappearing_whenRetainingOutgoingRows_thenItStaysAboveToday() {
        // given
        let old = [SidebarSection(bucket: .running, items: [row("running")]),
                   SidebarSection(bucket: .today, items: [row("today")])]
        let new = [SidebarSection(bucket: .today, items: [row("today")])]
        // when
        let retained = SidebarSection.retainingRemovedRows(from: old, in: new)
        // then
        #expect(retained.map(\.bucket) == [.running, .today])
    }
}
