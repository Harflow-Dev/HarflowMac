@testable import MainWindowFeature
@testable import MonitorCore
import PbTestUtilities
import PbUI
import Testing

/// Piece 2/3 of the Monitor architecture plan removed git from the Inspector entirely ("Files
/// changed" and the "Branch" row) — `InspectorModel` no longer carries a `changes` field at all,
/// so its remaining tests cover only the enforcement-not-recorded rule.
@Suite struct InspectorModelTests {

    // MARK: - Piece 2/3: InspectorModel builds with no `changes` field at all

    @Test func givenNoGitFieldAtAll_whenConstructed_thenTheModelStillBuildsWithEveryOtherField() {
        // given / when
        let task = TaskInfo(.object(["task_id": .string("abc123")]))!
        let model = InspectorModel(
            task: task, current: nil, stepCount: 3, activity: ActivityCounts(), subtaskCount: 1,
            ancestors: [], siblings: [], detail: task, hasSnapshot: true, notices: ["a notice"],
            startedBy: "Top-level task", resumeCommand: nil, onCopyResumeCommand: {}, onCopyTaskID: {}, onSelectTask: { _ in }
        )

        // then
        #expect(model.task.taskID == "abc123")
        #expect(model.stepCount == 3)
        #expect(model.subtaskCount == 1)
        #expect(model.notices == ["a notice"])
        #expect(model.startedBy == "Top-level task")
    }

    // MARK: - Item q: "Enforcement was not recorded" shows only when a snapshot exists
    
    @Test func givenNoSnapshotYet_whenAskingIfEnforcementNotRecordedShows_thenItDoesNotEvenWithoutEnforcement() {
        // given — no snapshot fetched yet: the absence of `enforcement` proves nothing.
        let detail = TaskInfo(.object(["task_id": .string("abc123")]))!
        
        // when / then
        #expect(!InspectorModel.showsEnforcementNotRecorded(detail: detail, hasSnapshot: false))
    }
    
    @Test func givenASnapshotWithNoEnforcement_whenAskingIfEnforcementNotRecordedShows_thenItDoes() {
        // given — a snapshot exists but genuinely carried no enforcement data.
        let detail = TaskInfo(.object(["task_id": .string("abc123")]))!
        
        // when / then
        #expect(InspectorModel.showsEnforcementNotRecorded(detail: detail, hasSnapshot: true))
    }
    
    @Test func givenASnapshotWithEnforcement_whenAskingIfEnforcementNotRecordedShows_thenItDoesNot() {
        // given
        let detail = TaskInfo(.object(["task_id": .string("abc123"), "enforcement": .object(["os_enforced": .bool(true)])]))!

        // when / then
        #expect(!InspectorModel.showsEnforcementNotRecorded(detail: detail, hasSnapshot: true))
    }

    // MARK: - "What was enforced" moved from the Summary tab (Summary item 15)

    private func model(enforcementLines: [String], hasSnapshot: Bool) -> InspectorModel {
        let task = TaskInfo(.object(["task_id": .string("abc123")]))!
        return InspectorModel(
            task: task, current: nil, stepCount: 3, activity: ActivityCounts(), subtaskCount: 1,
            ancestors: [], siblings: [], detail: task, hasSnapshot: hasSnapshot, notices: [],
            enforcementLines: enforcementLines,
            startedBy: "Top-level task", resumeCommand: nil, onCopyResumeCommand: {}, onCopyTaskID: {}, onSelectTask: { _ in }
        )
    }

    @Test func givenEnforcementData_whenMappedToLines_thenTheModelCarriesThemAndShowsTheSection() {
        // given — the same `PbUI.EnforcementText` mapping the Summary tab used before item 15.
        let detail = TaskInfo(.object(["task_id": .string("abc123"), "enforcement": .object(["os_enforced": .bool(true)])]))!

        // when
        let model = model(enforcementLines: EnforcementText.lines(detail.enforcement), hasSnapshot: true)

        // then
        #expect(model.enforcementLines == ["Restrictions enforced by the OS sandbox"])
        #expect(model.showsEnforcement)
    }

    @Test func givenNoEnforcementLinesAndNoSnapshot_whenConstructed_thenTheSectionHides() {
        // given — the snapshot hasn't loaded: absence proves nothing, so nothing shows yet.
        let model = model(enforcementLines: [], hasSnapshot: false)

        // when / then
        #expect(!model.showsEnforcement)
    }

    @Test func givenNoEnforcementLinesAndASettledSnapshot_whenConstructed_thenTheSectionShowsTheNotRecordedNote() {
        // given — a snapshot exists but carried no enforcement data at all.
        let model = model(enforcementLines: [], hasSnapshot: true)

        // when / then
        #expect(model.showsEnforcement)
    }
}

/// The VM wiring for item 15: `TaskDetailVM+Inspector.recomputeInspector(task:ancestors:allChildren:)`
/// maps the enforcement lines onto the inspector's model, not the view and not the Summary tab.
@MainActor
extension TaskDetailVMTests {

    @Test func givenEnforcementData_whenBuildingTheInspector_thenTheModelCarriesTheEnforcementLines() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running", enforcement: ["os_enforced": .bool(true)])
        harness.detailBox.value = running
        harness.sut.didAppear()

        // when
        harness.tasksSubject.send([running])

        // then
        await waitUntil { harness.sut.inspectorModel?.enforcementLines.isEmpty == false }
        #expect(harness.sut.inspectorModel?.enforcementLines == ["Restrictions enforced by the OS sandbox"])
        #expect(harness.sut.inspectorModel?.showsEnforcement == true)
    }
}
