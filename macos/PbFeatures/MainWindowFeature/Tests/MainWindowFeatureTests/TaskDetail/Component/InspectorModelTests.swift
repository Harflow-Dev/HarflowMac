@testable import MainWindowFeature
@testable import MonitorCore
import Testing

/// F4-41: files changed is capped at 12.
@Suite struct InspectorModelTests {
    
    @Test func givenMoreThan12ChangedFiles_whenListed_thenOnlyTheFirst12Show() {
        // given
        let files = (0 ..< 15).map { FileChange(status: "M", path: "file\($0).swift", oldPath: nil, added: 1, removed: 0) }
        
        // when
        let visible = InspectorModel.visibleFiles(files)
        
        // then
        #expect(visible.count == 12)
        #expect(visible.map(\.path) == files.prefix(12).map(\.path))
    }
    
    @Test func givenFewerThan12ChangedFiles_whenListed_thenAllShow() {
        // given
        let files = (0 ..< 3).map { FileChange(status: "M", path: "file\($0).swift", oldPath: nil, added: 1, removed: 0) }
        
        // when
        let visible = InspectorModel.visibleFiles(files)
        
        // then
        #expect(visible.count == 3)
    }
    
    // MARK: - Item k: "None" shows only once git actually compared and found nothing
    
    @Test func givenNoChangesYet_whenAskingIfNoFilesChangedShows_thenItDoesNot() {
        // given / when / then — `changes` is nil (still loading): never "None".
        #expect(!InspectorModel.showsNoFilesChanged(nil))
    }
    
    @Test func givenTheComparisonFailed_whenAskingIfNoFilesChangedShows_thenItDoesNot() {
        // given — not compared with the baseline: shows "Not compared…" instead, never "None".
        let changes = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: nil, labels: [], comparedWithBase: false)
        
        // when / then
        #expect(!InspectorModel.showsNoFilesChanged(changes))
    }
    
    @Test func givenAComparisonThatFoundNothing_whenAskingIfNoFilesChangedShows_thenItDoes() {
        // given — compared, and genuinely nothing changed.
        let changes = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: nil, labels: [], comparedWithBase: true)
        
        // when / then
        #expect(InspectorModel.showsNoFilesChanged(changes))
    }
    
    @Test func givenAComparisonThatFoundFiles_whenAskingIfNoFilesChangedShows_thenItDoesNot() {
        // given — compared, and files did change.
        let changes = GitChanges(
            files: [FileChange(status: "M", path: "a.swift", oldPath: nil, added: 1, removed: 0)],
            diffs: [], commitsSinceBase: nil, branch: nil, labels: [], comparedWithBase: true
        )
        
        // when / then
        #expect(!InspectorModel.showsNoFilesChanged(changes))
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
