//
//  TaskChangesReasons.swift
//  MainWindowFeature
//
//  One plain sentence per reason code of `task-changes.v1` (decision D-REASONS), derived from the contract's
//  vocabulary. Unknown codes and states are shown raw, with a sentence saying this version does not recognise them.
//

import Foundation

// MARK: - TaskChangesReasons

/// The sentence for every reason the contract names, plus the fallback for the ones it may add.
enum TaskChangesReasons {

    /// The sentence appended to an unrecognised reason code.
    static let unrecognisedReason = "Reason not recognised by this version."
    /// The sentence appended to an unrecognised state.
    static let unrecognisedState = "State not recognised by this version."

    /// Every code with a sentence, in contract order: capture, repository and scope, then row reasons.
    static let known: [String: String] = [
        // Capture
        "task_running": "The task is still running. Harflow captures repository differences once, after it settles.",
        "capture_settling": "The task has settled and its capture is still being stored.",
        "outcome_unobserved": "Harflow never observed this run's outcome, so it did not capture repository differences.",
        "capture_missing": "No stored capture was found for this task, although one was expected.",
        "no_repository": "The task finished without a repository recorded to compare.",
        "capture_error": "The capture failed while it was being taken.",
        "capture_too_large": "The stored capture is over the 8 MiB limit.",
        "changes_document_invalid": "The stored capture failed validation.",
        // Repository and scope
        "repository_identity_changed": "The repository no longer matches what was recorded when the task was dispatched. Nothing about it was read.",
        "object_store_untrusted": "The repository's object store failed Harflow's safety checks. Nothing about it was read.",
        "alternates_present": "This repository uses alternates, which capture never accepts. Nothing about it was read.",
        "head_missing": "The recorded head commit could not be found.",
        "base_missing": "No base commit was recorded, or it no longer exists.",
        "base_not_ancestor": "The recorded base is not an ancestor of the head.",
        "git_dir_unverified": "Its Git directory could not be verified, so no command was given this work tree.",
        "index_unsafe_path": "The head tree holds a path that is unsafe to compare, so nothing was read.",
        "tree_unreadable": "The head tree could not be read.",
        "capture_timeout": "Capture hit its time limit. Rows read so far are shown, and more may exist.",
        "output_ceiling": "A Git command hit its output limit. Rows read so far are shown, and more may exist.",
        "budget_exhausted": "Capture ran out of time before this repository was started.",
        "repository_unavailable": "The repository's directory is gone.",
        "git_failed": "Git failed while comparing this scope.",
        "listing_unparsable": "Git's file listing for this scope could not be understood.",
        "patch_alignment_failed": "The patch could not be matched to the listed files.",
        "patch_failed": "Git could not produce the patch.",
        "spawn_failed": "Git could not be started.",
        "index_refresh_failed": "Checking the tracked files against the head failed.",
        // Row
        "file_limit": "The stored patch is over the per-file text limit of 64 KiB, so its text is cut.",
        "task_limit": "The task's 1 MiB text allowance ran out.",
        "untracked": "Untracked files are listed by name only.",
        "submodule": "Submodules are never entered, so no text is stored.",
        "unmerged": "Unmerged files have no stored text.",
        "path_too_long": "The path is over 4096 bytes, so it is cut and has no text."
    ]

    /// The sentence for `code`, or the raw code with `unrecognisedReason` when the contract names no such reason.
    static func sentence(for code: String) -> String {
        if let sentence = known[code] { return sentence }
        return TaskChangesDisplayText.escaped(code) + ": " + unrecognisedReason
    }

    /// The sentence for an optional reason; `nil` when there is none.
    static func optionalSentence(for code: String?) -> String? { code.map { sentence(for: $0) } }

    /// The help sentence of a row's content state and reason. It differs from the scope-level sentence where the same
    /// code means something narrower for one patch.
    static func rowSentence(state: String, reason: String?) -> String? {
        switch (state, reason) {
        case ("truncated", "task_limit"): "The task's text allowance ran out partway through this patch."
        case ("omitted_size", "task_limit"): "The task's text allowance ran out before this file."
        case ("truncated", "capture_timeout"): "Capture hit its time limit while this patch was read, so its text is cut."
        case ("truncated", "output_ceiling"): "A Git command hit its output limit while this patch was read, so its text is cut."
        case (_, "capture_timeout"): "Capture hit its time limit before this patch was read, so its text was not captured."
        case (_, "output_ceiling"): "A Git command hit its output limit before this patch was read, so its text was not captured."
        default: optionalSentence(for: reason)
        }
    }

    /// An unrecognised state, raw, with its sentence.
    static func unrecognisedStateText(_ rawState: String) -> String {
        TaskChangesDisplayText.escaped(rawState) + ": " + unrecognisedState
    }
}
