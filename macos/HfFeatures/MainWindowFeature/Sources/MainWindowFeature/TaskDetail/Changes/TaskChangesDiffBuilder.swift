//
//  TaskChangesDiffBuilder.swift
//  MainWindowFeature
//
//  Builds what is drawn for a selected row: a classified diff from a patch, or a note from a failed read. Pure and
//  off the main actor. Diff text goes into the returned model only; it is never logged, described or persisted.
//

import Foundation
import HfRepository
import MonitorCore

// MARK: - TaskChangesDiffBuilder

enum TaskChangesDiffBuilder {

    /// The note title for any diff that could not be read.
    static let failureTitle = "This diff couldn't be read"
    static let bytesNotice = "Bytes, not UTF-8"
    static let crlfNotice = "Lines end in CRLF"
    static let workingTreeCaption = "Counts and patch for this scope are separate observations and can differ."

    /// What a failed text read asks for.
    enum Failure: Equatable, Sendable {
        /// `changes_entry_not_found` or `changes_cursor_expired`: the stored changes were replaced; reload the listing.
        case reload
        /// The read stopped at its own request or time bound.
        case clientBound
        /// Any other failure.
        case other

        /// The note drawn for this failure.
        var note: TaskChangesNote {
            switch self {
            case .reload:
                TaskChangesNote(tone: .warn, title: failureTitle,
                                detail: "The stored changes were replaced since this list loaded. Reload the list, then choose the row again.",
                                action: .reloadChanges)
            case .clientBound:
                TaskChangesNote(tone: .warn, title: failureTitle, detail: TaskChangesFailure.clientBoundSentence, action: .retryDiff)
            case .other:
                TaskChangesNote(tone: .warn, title: failureTitle, detail: "The engine did not give the stored text. No diff is implied.",
                                action: .retryDiff)
            }
        }
    }

    /// Classifies a failed patch read. A superseded outcome that reaches here is one the caller already repeated once while its
    /// fence was current, so it is shown as an ordinary failure.
    static func classify(_ outcome: TaskChangesReadFailure.Outcome) -> Failure {
        switch outcome {
        case .clientBound: .clientBound
        case .superseded: .other
        case .failed(let error):
            switch error.refusalCode {
            case TaskChangesRefusalCode.entryNotFound, TaskChangesRefusalCode.cursorExpired: .reload
            default: .other
            }
        }
    }

    /// The diff of a read patch for the row described by `facts`; `.none` when the surrounding task is cancelled first.
    static func build(patch: TaskChangesPatch, header: TaskChangesDiffHeader, facts: TaskChangesRowFacts) -> TaskChangesDiffPresentation {
        let utf8 = patch.utf8String
        let lines = UnifiedDiffLines.classify(utf8 ?? patch.displayString)
        var hasher = Hasher()
        hasher.combine(patch.bytes)
        hasher.combine(header.path)
        guard let text = TaskChangesDiffText.build(lines: lines, identity: hasher.finalize()) else { return .none }
        return .diff(TaskChangesDiffModel(
            header: header, text: text, notice: utf8 == nil ? bytesNotice : nil,
            lineEndingNotice: lines.contains { $0.hadCarriageReturn } ? crlfNotice : nil, tail: tail(patch.content),
            caption: facts.countsAndPatchSeparate ? workingTreeCaption : nil))
    }

    /// "Stored text ends here · ..." for a truncated patch.
    static func tail(_ content: TaskChangesContent) -> String? {
        guard content.state == .truncated else { return nil }
        switch content.reason {
        case "file_limit": return "Stored text ends here · 64 KiB of a larger patch"
        case "task_limit": return "Stored text ends here · task limit"
        case "capture_timeout", "output_ceiling": return "Stored text ends here · time or output limit"
        default: return "Stored text ends here"
        }
    }
}
