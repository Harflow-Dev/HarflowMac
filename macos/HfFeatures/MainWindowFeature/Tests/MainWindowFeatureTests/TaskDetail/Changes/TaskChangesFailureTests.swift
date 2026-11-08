import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskChangesFailureTests

/// Failure mapping uses typed outcomes only: a refusal code, an unsupported command, the repository's own client bound.
struct TaskChangesFailureTests {

    private func classify(_ error: ToolError) -> TaskChangesFailure? { TaskChangesFailure.classify(.failed(error)) }

    // MARK: Outcomes

    @Test func givenASupersededRead_whenClassified_thenItIsNotAFailure() {
        // given / when
        let failure = TaskChangesFailure.classify(.superseded)
        // then
        #expect(failure == nil)
    }

    @Test(arguments: [TaskChangesReadFailure.ClientBound.deadline, .requestBudget])
    func givenAClientBound_whenClassified_thenItIsTheClientBoundFailure(bound: TaskChangesReadFailure.ClientBound) {
        // given / when
        let failure = TaskChangesFailure.classify(.clientBound(bound))
        // then
        #expect(failure == .clientBound)
    }

    @Test func givenAPerCommandTimeout_whenClassified_thenItIsUnavailableNotTheClientBound() {
        // given
        let timeout = ToolError.timedOut(tool: "harflow-ctl", seconds: 30)
        // when
        let failure = classify(timeout)
        // then
        #expect(failure == .unavailable)
        #expect(failure != .clientBound)
    }

    @Test func givenAnUnsupportedCommand_whenClassified_thenTheEngineDoesNotSupportChanges() {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-changes", detail: "usage: invalid choice")
        // when / then
        #expect(classify(error) == .unsupported)
    }

    @Test(arguments: [
        ToolError.notFound(tool: "harflow-ctl", searched: ["/x"]),
        .unsupportedVersion(tool: "harflow-ctl", version: "9"),
        .unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "changes_cursor_expired in prose"),
        .unknownOutcome(message: "no answer"),
        .launchFailed(tool: "harflow-ctl", detail: "spawn"),
        .timedOut(tool: "harflow-ctl", seconds: 30)
    ])
    func givenAFailureWithoutARefusalCode_whenClassified_thenItIsUnavailable(error: ToolError) {
        // given / when / then
        #expect(classify(error) == .unavailable)
    }

    // MARK: Refusals

    @Test func givenEachNamedRefusal_whenClassified_thenItMapsToItsState() {
        // given / when / then
        #expect(classify(ChangesJSON.pendingLaunch) == .notStarted)
        #expect(classify(ChangesJSON.directCallerRefused) == .callerRefused)
        #expect(classify(.refused(code: "agent_caller", message: "agent")) == .callerRefused)
        #expect(classify(ChangesJSON.unknownTask) == .unknownTask)
        #expect(classify(ChangesJSON.pageTooLarge) == .readRefused(code: "changes_page_too_large"))
        #expect(classify(ChangesJSON.cursorInvalid) == .readRefused(code: "changes_cursor_invalid"))
        #expect(classify(ChangesJSON.cursorExpired) == .readRefused(code: "changes_cursor_expired"))
        #expect(classify(ChangesJSON.entryNotFound) == .readRefused(code: "changes_entry_not_found"))
        #expect(classify(.refused(code: "something_new", message: "")) == .readRefused(code: "something_new"))
    }

    // MARK: Notes

    @Test func givenEachFailure_whenItsNoteIsBuilt_thenTheCopyAndActionFollowThePlan() {
        // given / when
        let unsupported = TaskChangesFailure.unsupported.note
        let notStarted = TaskChangesFailure.notStarted.note
        let caller = TaskChangesFailure.callerRefused.note
        let unknown = TaskChangesFailure.unknownTask.note
        let bound = TaskChangesFailure.clientBound.note
        let unavailable = TaskChangesFailure.unavailable.note
        // then
        #expect(unsupported.title == "This engine does not support Changes")
        #expect(unsupported.action == .retryRead, "an unsupported engine offers Retry, since it cannot observe an upgrade")
        #expect(notStarted.title == "Available once this task starts")
        #expect(notStarted.action == nil)
        #expect(caller.detail == "The engine refused this read for this caller.")
        #expect(caller.action == nil)
        #expect(unknown.detail == "The engine no longer knows this task.")
        #expect(unknown.action == nil)
        #expect(bound.detail == TaskChangesFailure.clientBoundSentence)
        #expect(bound.detail == "This view stopped reading the stored changes after its request or time limit; "
            + "they may be complete. Try again to read them from the start.")
        #expect(bound.action == .retryRead)
        #expect(unavailable.detail == "The engine did not answer. No changes are implied.")
        #expect(unavailable.action == .retryRead)
    }

    @Test(arguments: [
        ("changes_page_too_large", "The engine could not fit a page of the stored changes into one answer."),
        ("changes_cursor_invalid", "The engine rejected the position this view asked to continue from."),
        ("changes_cursor_expired", "The stored changes kept changing while they were read."),
        ("changes_entry_not_found", "The engine refused this read.")
    ])
    func givenAReadRefusal_whenItsNoteIsBuilt_thenItHasASentenceTheCodeAndRetry(code: String, sentence: String) {
        // given / when
        let note = TaskChangesFailure.readRefused(code: code).note
        // then
        #expect(note.title == "Stored changes unavailable")
        #expect(note.detail == sentence)
        #expect(note.reason == code.replacingOccurrences(of: "\\", with: "\\\\"))
        #expect(note.action == .retryRead)
    }

    @Test func givenARefusalCodeWithControls_whenItsNoteIsBuilt_thenTheCodeIsEscaped() {
        // given / when
        let note = TaskChangesFailure.readRefused(code: "x\u{202E}y").note
        // then
        #expect(note.reason == "x\\u{202E}y")
    }
}
