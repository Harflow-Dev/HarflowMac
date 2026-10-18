@testable import MainWindowFeature
import Testing

// MARK: - WorkflowRunnerLaunchPolicyTests

@Suite struct WorkflowRunnerLaunchPolicyTests {
    @Test func givenRequestedSavedDefinition_whenReadCompletes_thenLaunchMayOpen() {
        // given / when / then
        #expect(WorkflowRunnerLaunchPolicy.canLaunch(pendingName: "Review", loadedName: "Review", loadingKind: nil,
                                                    loadFailed: false, hasUnsavedChanges: false))
    }

    @Test func givenIncompleteOrUnsafeDefinition_whenLaunchChecked_thenItStaysClosed() {
        // given
        let scenarios: [(String?, String, String?, Bool, Bool)] = [
            (nil, "Review", nil, false, false),
            ("", "", nil, false, false),
            ("Review", "Previous", nil, false, false),
            ("Review", "Review", "editor", false, false),
            ("Review", "Review", nil, true, false),
            ("Review", "Review", nil, false, true)
        ]
        // when / then
        for (pending, loaded, loading, failed, unsaved) in scenarios {
            #expect(!WorkflowRunnerLaunchPolicy.canLaunch(pendingName: pending, loadedName: loaded, loadingKind: loading,
                                                         loadFailed: failed, hasUnsavedChanges: unsaved))
        }
    }

    @MainActor @Test func givenRunnerDraftStore_whenSavedOrRemoved_thenEditorDraftsAreNeverRestored() throws {
        // given
        let store = WorkflowRunnerDraftStore()
        // when
        try store.save([:], key: "saved:Review")
        try store.remove(key: "saved:Review")
        // then
        #expect(try store.load(key: "saved:Review") == nil)
    }
}
