import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - TaskChangesReasonsTests

/// One plain sentence per reason code of the contract, and the fallback for the ones it may add.
struct TaskChangesReasonsTests {
    private static let captureReasons = [
        "task_running", "capture_settling", "outcome_unobserved", "capture_missing", "no_repository", "capture_error",
        "capture_too_large", "changes_document_invalid"
    ]
    private static let repositoryAndScopeReasons = [
        "repository_identity_changed", "object_store_untrusted", "alternates_present", "head_missing", "base_missing",
        "base_not_ancestor", "git_dir_unverified", "index_unsafe_path", "tree_unreadable", "capture_timeout", "output_ceiling",
        "budget_exhausted", "repository_unavailable", "capture_error", "git_failed", "listing_unparsable", "patch_alignment_failed",
        "patch_failed", "spawn_failed", "index_refresh_failed"
    ]
    private static let rowReasons = ["file_limit", "task_limit", "untracked", "submodule", "unmerged", "path_too_long"]
    private static let allReasons = Array(Set(captureReasons + repositoryAndScopeReasons + rowReasons)).sorted()

    @Test func givenTheContractReasons_whenListed_thenTheTableHoldsExactlyThose() {
        // given
        let expected = Set(Self.allReasons)
        // when
        let keys = Set(TaskChangesReasons.known.keys)
        // then
        #expect(keys == expected)
        #expect(expected.count == 33)
    }

    @Test(arguments: allReasons)
    func givenAKnownReason_whenAskedForItsSentence_thenItIsTheTableEntryAndIsPlain(code: String) throws {
        // given
        let entry = try #require(TaskChangesReasons.known[code])
        // when
        let sentence = TaskChangesReasons.sentence(for: code)
        // then
        #expect(sentence == entry)
        #expect(sentence.hasSuffix("."))
        #expect(!sentence.contains("_"), "a sentence never shows the raw code")
        #expect(!sentence.contains("2-second") && !sentence.contains("2 second"))
        #expect(TaskChangesReasons.optionalSentence(for: code) == entry)
    }

    @Test func givenAnUnknownReason_whenAskedForItsSentence_thenItShowsTheRawCodeAndSaysItIsNotRecognised() {
        // given / when
        let sentence = TaskChangesReasons.sentence(for: "future_reason")
        // then
        #expect(sentence == "future_reason: Reason not recognised by this version.")
    }

    @Test func givenAnUnknownReasonWithControls_whenAskedForItsSentence_thenTheCodeIsEscaped() {
        // given / when
        let sentence = TaskChangesReasons.sentence(for: "bad\u{202E}\\code")
        // then
        #expect(sentence == "bad\\u{202E}\\\\code: Reason not recognised by this version.")
    }

    @Test func givenNoReason_whenAskedForAnOptionalSentence_thenThereIsNone() {
        // given / when / then
        #expect(TaskChangesReasons.optionalSentence(for: nil) == nil)
    }

    @Test func givenAnUnrecognisedState_whenDescribed_thenTheRawStateIsEscapedWithItsSentence() {
        // given / when
        let text = TaskChangesReasons.unrecognisedStateText("odd\u{200B}state")
        // then
        #expect(text == "odd\\u{200B}state: State not recognised by this version.")
    }

    // MARK: Row sentences

    @Test(arguments: [
        ("truncated", "task_limit", "The task's text allowance ran out partway through this patch."),
        ("omitted_size", "task_limit", "The task's text allowance ran out before this file."),
        ("truncated", "capture_timeout", "Capture hit its time limit while this patch was read, so its text is cut."),
        ("truncated", "output_ceiling", "A Git command hit its output limit while this patch was read, so its text is cut."),
        ("truncated", "file_limit", "The stored patch is over the per-file text limit of 64 KiB, so its text is cut."),
        ("not_captured", "capture_timeout", "Capture hit its time limit before this patch was read, so its text was not captured."),
        ("not_captured", "output_ceiling", "A Git command hit its output limit before this patch was read, so its text was not captured."),
        ("not_captured", "untracked", "Untracked files are listed by name only.")
    ])
    func givenARowStateAndReason_whenAskedForItsRowSentence_thenStreamCausesGetTheirOwnWording(state: String, reason: String, sentence: String) {
        // given / when
        let result = TaskChangesReasons.rowSentence(state: state, reason: reason)
        // then
        #expect(result == sentence)
    }

    @Test func givenNoReasonOrAnUnknownOne_whenAskedForItsRowSentence_thenThereIsNoneOrTheRawFallback() {
        // given / when / then
        #expect(TaskChangesReasons.rowSentence(state: "available", reason: nil) == nil)
        #expect(TaskChangesReasons.rowSentence(state: "truncated", reason: "novel") == "novel: Reason not recognised by this version.")
    }

    @Test func givenTheFileAndTaskLimitReasons_whenWorded_thenTheScopeSentencesDifferFromTheRowOnes() {
        // given / when
        let file = TaskChangesReasons.sentence(for: "file_limit")
        let task = TaskChangesReasons.sentence(for: "task_limit")
        // then
        #expect(file == TaskChangesReasons.rowSentence(state: "truncated", reason: "file_limit"))
        #expect(task == "The task's 1 MiB text allowance ran out.")
        #expect(task != TaskChangesReasons.rowSentence(state: "truncated", reason: "task_limit"))
    }
}
