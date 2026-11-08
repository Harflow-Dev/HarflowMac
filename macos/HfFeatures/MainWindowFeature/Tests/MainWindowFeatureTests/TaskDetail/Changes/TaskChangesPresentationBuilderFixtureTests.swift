import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskChangesPresentationBuilderFixtureTests

/// The 10 listing documents and 7 refusals of the vendored bundle, restated inline and mapped through the presentation.
struct TaskChangesPresentationBuilderFixtureTests {

    // MARK: Documents

    @Test func givenTheAvailableListingReadAcrossTwoPages_whenBuilt_thenItIsADocumentWithTheSummedTabCount() throws {
        // given: ctl-task-changes-available-listing.json plus ctl-task-changes-listing-next-page.json
        let snapshot = try ChangesJSON.availableListing()

        // when
        let built = TaskChangesPresentationBuilder.built(snapshot, taskID: "task-changes-available")

        // then
        let document = try #require(built.document)
        #expect(snapshot.pagesRead == 2)
        #expect(built.tabCount == 6)
        #expect(!built.isSettling && !built.wasSuperseded)
        #expect(document.banner == nil)
        #expect(document.caption == nil)
        #expect(document.countCaption == TaskChangesPresentationBuilder.countCaption, "src/app.py is in both scopes")
        let repository = try #require(document.repositories.first)
        #expect(document.repositories.count == 1)
        #expect(repository.name == "repo")
        #expect(repository.count == "6")
        #expect(repository.startsOpen)
        #expect(repository.tag == nil)
        #expect(repository.attribution == TaskChangesRepositoryEntry.attribution)
        #expect(repository.notes.isEmpty)
        #expect(repository.facts.map(\.term) == ["Base", "Head", "Working tree", "Observed", "Started dirty"])
        #expect(repository.facts.first?.value == "aaaaaaa \u{B7} dispatch")
        #expect(repository.facts.last?.value == "No")
        let committed = try #require(repository.scopes.first)
        let working = try #require(repository.scopes.last)
        #expect(committed.id == TaskChangesScopeID(taskID: "task-changes-available", repository: 0, scope: "committed_range"))
        #expect(committed.title == "Committed" && committed.count == "4" && committed.tag == nil && committed.captions.isEmpty)
        #expect(committed.rows.map(\.path) == ["README.md", "docs/guide.md", "src/app.py", "assets/logo.png"])
        #expect(committed.rows.map(\.letter) == ["A", "A", "M", "A"])
        #expect(committed.rows.allSatisfy { $0.stateHelp == nil || $0.state == "Binary" }, "ordinary rows carry no help")
        #expect(committed.rows.last?.state == "Binary")
        #expect(committed.rows.last?.additions == nil && committed.rows.last?.deletions == nil)
        #expect(working.title == "Working tree" && working.count == "2")
        #expect(working.captions == [TaskChangesPresentationBuilder.workingTreeCaption])
        #expect(working.rows.map(\.letter) == ["M", "?"])
        #expect(working.rows.last?.state == "Name only")
        #expect(working.rows.allSatisfy { !$0.isDimmed })
    }

    @Test func givenTheIncompleteDocument_whenBuilt_thenTheBannerPlusPlusCountsAndNoTabCountShow() throws {
        // given: ctl-task-changes-incomplete.json
        let snapshot = try ChangesJSON.incomplete()

        // when
        let built = TaskChangesPresentationBuilder.built(snapshot)

        // then
        let document = try #require(built.document)
        #expect(built.tabCount == nil)
        let banner = try #require(document.banner)
        #expect(banner.tone == .warn && banner.title == "Capture incomplete")
        #expect(banner.reason == TaskChangesReasons.sentence(for: "capture_timeout"))
        let repository = try #require(document.repositories.first)
        #expect(repository.tag == TaskChangesTag(text: "Incomplete", tone: .warn))
        #expect(repository.count == "1+")
        #expect(repository.notes.map(\.title) == [TaskChangesReasons.sentence(for: "capture_timeout")])
        let committed = try #require(repository.scopes.first)
        #expect(committed.count == "1+")
        #expect(committed.tag == TaskChangesTag(text: "Incomplete \u{B7} time limit", tone: .warn))
        #expect(committed.captions == [TaskChangesReasons.sentence(for: "capture_timeout")])
        #expect(committed.rows.first?.state == "Truncated \u{B7} time or output limit")
        let working = try #require(repository.scopes.last)
        #expect(working.count == "0+", "an available scope inside an incomplete repository understates")
        #expect(working.captions == [TaskChangesPresentationBuilder.noRows], "an incomplete capture never claims no differences")
        #expect(document.caption == nil)
    }

    @Test func givenTheNoRepositoryDocument_whenBuilt_thenItIsTheNoRepositoryNoteWithoutACount() throws {
        // given: ctl-task-changes-no-repository.json
        let built = TaskChangesPresentationBuilder.built(try ChangesJSON.noRepository())
        // then
        let note = try #require(built.note)
        #expect(note.title == "No repository recorded")
        #expect(note.action == nil)
        #expect(built.tabCount == nil)
    }

    @Test(arguments: [("missing", "capture_missing"), ("unobserved", "outcome_unobserved")])
    func givenANotCapturedDocument_whenBuilt_thenItIsTheNotCapturedNoteWithItsReason(name: String, reason: String) throws {
        // given: ctl-task-changes-not-captured-missing.json and ctl-task-changes-not-captured-unobserved.json
        let snapshot = try ChangesJSON.captureOnly(task: "task-changes-\(name)", state: "not_captured", reason: reason)
        // when
        let built = TaskChangesPresentationBuilder.built(snapshot)
        // then
        let note = try #require(built.note)
        #expect(note.title == "Changes not captured")
        #expect(note.reason == TaskChangesReasons.sentence(for: reason))
        #expect(note.action == nil)
        #expect(built.tabCount == nil)
        #expect(!built.isSettling)
    }

    @Test func givenThePendingRunningDocument_whenBuilt_thenItWaitsWithoutSettlingOrACount() throws {
        // given: ctl-task-changes-pending-running.json
        let built = TaskChangesPresentationBuilder.built(try ChangesJSON.pendingRunning())
        // then
        let note = try #require(built.note)
        #expect(note.title == "No changes to show while this runs")
        #expect(note.caption == "Edits the agent reports appear in the transcript. They are not this capture.")
        #expect(note.action == nil)
        #expect(!built.isSettling)
        #expect(built.tabCount == nil)
    }

    @Test func givenThePendingSettlingDocument_whenBuilt_thenItIsSettlingWithASkeleton() throws {
        // given: ctl-task-changes-pending-settling.json
        let built = TaskChangesPresentationBuilder.built(try ChangesJSON.pendingSettling())
        // then
        let note = try #require(built.note)
        #expect(note.title == "Stored changes aren't available yet")
        #expect(note.skeletonBars == 3)
        #expect(note.action == nil)
        #expect(built.isSettling)
        #expect(built.tabCount == nil)
    }

    @Test(arguments: ["capture_error", "changes_document_invalid"])
    func givenAnUnavailableDocument_whenBuilt_thenItIsTheErrorNoteWithTheReasonAndRetry(reason: String) throws {
        // given: ctl-task-changes-unavailable.json and ctl-task-changes-document-invalid.json
        let snapshot = try ChangesJSON.captureOnly(task: "task-changes-unavailable", state: "unavailable", reason: reason)
        // when
        let built = TaskChangesPresentationBuilder.built(snapshot)
        // then
        let note = try #require(built.note)
        #expect(note.title == "Stored changes unavailable")
        #expect(note.reason == TaskChangesReasons.sentence(for: reason))
        #expect(note.action == .retryRead)
        #expect(built.tabCount == nil)
    }

    // MARK: Refusals

    @Test func givenEachRefusalFixture_whenBuilt_thenItMapsToItsStateAndNeverACount() throws {
        // given: cursor-expired (restarts exhausted), cursor-invalid, direct-caller-refused, entry-not-found, page-too-large,
        // pending-launch and unknown-task
        let cases: [(ToolError, String, TaskChangesNote.Action?)] = [
            (ChangesJSON.cursorExpired, "Stored changes unavailable", .retryRead),
            (ChangesJSON.cursorInvalid, "Stored changes unavailable", .retryRead),
            (ChangesJSON.directCallerRefused, "Stored changes unavailable", nil),
            (ChangesJSON.entryNotFound, "Stored changes unavailable", .retryRead),
            (ChangesJSON.pageTooLarge, "Stored changes unavailable", .retryRead),
            (ChangesJSON.pendingLaunch, "Available once this task starts", nil),
            (ChangesJSON.unknownTask, "Stored changes unavailable", nil)
        ]

        for (error, title, action) in cases {
            // when
            let built = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.failed(error)))

            // then
            let note = try #require(built.note, "\(error)")
            #expect(note.title == title)
            #expect(note.action == action, "\(error)")
            #expect(built.tabCount == nil && !built.isSettling && !built.wasSuperseded)
        }
    }

    @Test func givenTheCursorExpiredRefusal_whenBuilt_thenTheSentenceSaysTheChangesKeptChanging() throws {
        // given / when
        let built = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.failed(ChangesJSON.cursorExpired)))
        // then
        #expect(built.note?.detail == "The stored changes kept changing while they were read.")
        #expect(built.note?.reason == "changes_cursor_expired")
    }

    @Test func givenTheCallerAndUnknownTaskRefusals_whenBuilt_thenTheDetailSentencesMatch() throws {
        // given / when
        let caller = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.failed(ChangesJSON.directCallerRefused)))
        let unknown = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.failed(ChangesJSON.unknownTask)))
        // then
        #expect(caller.note?.detail == "The engine refused this read for this caller.")
        #expect(unknown.note?.detail == "The engine no longer knows this task.")
    }

    // MARK: Failures without a document

    @Test func givenAClientBoundOutcome_whenBuilt_thenItIsTheReadingStoppedNoteWithRetry() throws {
        // given / when
        let built = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.clientBound(.deadline)))
        // then
        let note = try #require(built.note)
        #expect(note.title == "Reading stopped early")
        #expect(note.detail == TaskChangesFailure.clientBoundSentence)
        #expect(note.action == .retryRead)
    }

    @Test func givenAnUnsupportedCommand_whenBuilt_thenTheNoteOffersRetry() throws {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-changes", detail: "")
        // when
        let built = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.failed(error)))
        // then
        #expect(built.note?.title == "This engine does not support Changes")
        #expect(built.note?.action == .retryRead)
    }

    @Test func givenASupersededOutcome_whenBuilt_thenItIsMarkedSupersededAndShowsLoading() {
        // given / when
        let built = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.superseded))
        // then
        #expect(built.wasSuperseded)
        #expect(built.presentation == .loading)
        #expect(built.tabCount == nil)
    }

    @Test func givenTheTransportTimeout_whenBuilt_thenTheUnavailableNoteShows() {
        // given
        let timeout = ToolError.timedOut(tool: "harflow-ctl", seconds: 30)
        // when
        let built = TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.failed(timeout)))
        // then
        #expect(built.note?.detail == "The engine did not answer. No changes are implied.")
        #expect(built.note?.action == .retryRead)
    }

    @Test func givenTheCappedSettlingPresentation_whenRead_thenItOffersCheckAgain() {
        // given / when
        let presentation = TaskChangesPresentation.settlingCapped
        // then
        guard case .note(let note) = presentation else { Issue.record("not a note"); return }
        #expect(note.action == .checkAgain)
        #expect(note.action?.title == "Check again")
        #expect(note.detail == "Capture may still be settling. This view stopped checking.")
    }
}
