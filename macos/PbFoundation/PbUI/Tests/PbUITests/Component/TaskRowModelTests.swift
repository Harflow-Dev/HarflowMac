import MonitorCore
@testable import PbUI
import SwiftUI
import Testing

/// `TaskRowModel`'s tree fields default to values that keep MenuBar's plain row free of a gutter,
/// the chevron's accessibility text is task-specific, and the subtitle is "<repo> · <Backend>".
@Suite struct TaskRowModelTests {

    private func model(
        backend: String = "claude", status: TaskStatus = .completed, repoName: String = "repo", subTaskSummary: String? = nil,
        hasChildren: Bool = false, isExpanded: Bool = true, guides: [TreeGuide] = []
    ) -> TaskRowModel {
        TaskRowModel(
            id: "t1", backend: backend, title: "Fix the login bug", status: status, repoName: repoName, ageText: "3h",
            subTaskSummary: subTaskSummary, hasChildren: hasChildren, isExpanded: isExpanded, guides: guides
        )
    }

    @Test func givenNoTreeFieldsPassed_whenConstructed_thenDefaultsMatchMenuBarsPlainRow() {
        // given / when
        let row = model()

        // then — MenuBar never sets these, so a chevron/gutter must never render for it.
        #expect(row.hasChildren == false)
        #expect(row.isExpanded == true)
        #expect(row.guides.isEmpty)
        #expect(row.indent == 0)
    }

    @Test func givenARepoAndBackend_whenReadingTheSubtitle_thenItIsRepoNameDotCapitalisedBackend() {
        // given
        let row = model(backend: "vibe", repoName: "polybridge")

        // when / then
        #expect(row.subtitle == "polybridge · Vibe")
    }

    @Test func givenASubTaskSummary_whenReadingTheSubtitle_thenItIsAppended() {
        // given
        let row = model(subTaskSummary: "2 sub-tasks, 1 running")

        // when / then
        #expect(row.subtitle == "repo · Claude · 2 sub-tasks, 1 running")
    }

    @Test func givenAnEmptyRepoName_whenReadingTheSubtitle_thenOnlyTheBackendShows() {
        // given
        let row = model(repoName: "")

        // when / then
        #expect(row.subtitle == "Claude")
    }

    @Test func givenAnUnknownBackend_whenReadingTheSubtitle_thenItsNameIsCapitalised() {
        // given
        let row = model(backend: "mystery")

        // when / then
        #expect(row.subtitle == "repo · Mystery")
    }

    @Test func givenEachStatus_whenReadingIsRunning_thenOnlyRunningIsTrue() {
        // given / when / then
        #expect(model(status: .running).isRunning)
        #expect(!model(status: .completed).isRunning)
        #expect(!model(status: .failed).isRunning)
    }

    @Test func givenAnExpandedRow_whenAskedForItsChevronAccessibility_thenItSaysCollapse() {
        // given
        let row = model(hasChildren: true, isExpanded: true)

        // when / then
        #expect(row.chevronAccessibilityLabel == "Collapse Fix the login bug")
        #expect(row.chevronAccessibilityValue == "Expanded")
    }

    @Test func givenACollapsedRow_whenAskedForItsChevronAccessibility_thenItSaysExpand() {
        // given
        let row = model(hasChildren: true, isExpanded: false)

        // when / then
        #expect(row.chevronAccessibilityLabel == "Expand Fix the login bug")
        #expect(row.chevronAccessibilityValue == "Collapsed")
    }

    @Test func givenAThreeLevelTreesGuides_whenStored_thenTheyRoundTripUnchanged() {
        // given / when
        let row = model(guides: [.continuation, .last])

        // then — the model is a plain data carrier; `TreeGutter` (untestable without an AppKit
        // host) is the only consumer that interprets these.
        #expect(row.guides == [.continuation, .last])
    }
}

// MARK: - GroupRowHelperTests

@Suite struct GroupRowHelperTests {

    @Test func givenFinishedAndTotal_whenBuildingTheSubtitle_thenItReadsNOfMFinished() {
        // given / when / then
        #expect(GroupRow.subtitle(finished: 3, total: 5) == "Parallel run · 3 of 5 finished")
    }

    @Test func givenAGroupOfOne_whenBuildingTheSubtitle_thenItReadsGroupAndTheMembersStatus() {
        // given / when / then
        #expect(GroupRow.subtitle(finished: 1, total: 1, singleMemberStatus: .completed) == "Group · Done")
        #expect(GroupRow.subtitle(finished: 0, total: 1, singleMemberStatus: .running) == "Group · Running")
    }

    @Test func givenTwoOrMoreMembers_whenBuildingTheSubtitle_thenItStaysAParallelRunEvenWithAStatus() {
        // given / when / then
        #expect(GroupRow.subtitle(finished: 1, total: 2, singleMemberStatus: .completed) == "Parallel run · 1 of 2 finished")
    }

    @Test func givenFinishedAndTotal_whenComputingProgress_thenItIsTheClampedFraction() {
        // given / when / then
        #expect(GroupRow.progress(finished: 1, total: 4) == 0.25)
        #expect(GroupRow.progress(finished: 9, total: 4) == 1)
        #expect(GroupRow.progress(finished: 0, total: 0) == 0)
    }

    @Test func givenAGroup_whenDecidingTheBar_thenItShowsOnlyWhileAnyMemberRuns() {
        // given / when / then
        #expect(GroupRow.showsProgress(anyRunning: true))
        #expect(!GroupRow.showsProgress(anyRunning: false))
    }
}
