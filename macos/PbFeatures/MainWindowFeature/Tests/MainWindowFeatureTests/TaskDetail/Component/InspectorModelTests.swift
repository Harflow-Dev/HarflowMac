@testable import MainWindowFeature
@testable import MonitorCore
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
            ancestors: [], siblings: [], detail: task, hasSnapshot: true, notices: ["a notice"], onSelectTask: { _ in }
        )

        // then
        #expect(model.task.taskID == "abc123")
        #expect(model.stepCount == 3)
        #expect(model.subtaskCount == 1)
        #expect(model.notices == ["a notice"])
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
}
