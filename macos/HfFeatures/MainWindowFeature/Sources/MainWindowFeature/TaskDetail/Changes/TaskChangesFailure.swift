//
//  TaskChangesFailure.swift
//  MainWindowFeature
//
//  Maps a failed stored-changes read to the note the pane shows. Only typed outcomes decide: a refusal code, an
//  unsupported command, the repository's own client bound. Nothing matches on stderr text.
//

import HfRepository
import MonitorCore

// MARK: - TaskChangesFailure

/// Why a read produced no listing, reduced to what the pane distinguishes.
enum TaskChangesFailure: Equatable, Sendable {
    /// The engine lacks `task-changes.v1`, or an older engine answered with a usage error.
    case unsupported
    /// Refusal `task_pending_launch`.
    case notStarted
    /// Refusals `agent_caller` and `caller_undecidable`.
    case callerRefused
    /// Refusal `unknown_task`.
    case unknownTask
    /// A refusal that survived the repository's restarts: too large a page, a bad cursor, an expired cursor.
    case readRefused(code: String)
    /// The read stopped at its own request or time bound.
    case clientBound
    /// A per-command timeout or any other failure to get an answer.
    case unavailable

    /// The sentence for a read that stopped at its own bound. A copy deviation from the design (D-PAGING).
    static let clientBoundSentence = "This view stopped reading the stored changes after its request or time limit; they may be complete. "
        + "Try again to read them from the start."

    /// Classifies a failed read; `nil` for a superseded one, which is never an error state.
    static func classify(_ outcome: TaskChangesReadFailure.Outcome) -> TaskChangesFailure? {
        switch outcome {
        case .superseded: nil
        case .clientBound: .clientBound
        case .failed(let error): classify(error)
        }
    }

    /// Classifies a tool error from a listing read.
    static func classify(_ error: ToolError) -> TaskChangesFailure {
        if case .unsupportedCommand = error { return .unsupported }
        switch error.refusalCode {
        case TaskChangesRefusalCode.taskPendingLaunch: return .notStarted
        case "agent_caller", "caller_undecidable": return .callerRefused
        case "unknown_task": return .unknownTask
        case .some(let code): return .readRefused(code: code)
        case nil: return .unavailable
        }
    }

    /// The pane note for this failure.
    var note: TaskChangesNote {
        switch self {
        case .unsupported:
            TaskChangesNote(tone: .warn, title: "This engine does not support Changes",
                            detail: "The engine in use does not offer stored changes.", action: .retryRead)
        case .notStarted:
            TaskChangesNote(tone: .info, title: "Available once this task starts",
                            detail: "A task waiting to launch has no record to read yet.")
        case .callerRefused:
            TaskChangesNote(tone: .warn, title: "Stored changes unavailable",
                            detail: "The engine refused this read for this caller.")
        case .unknownTask:
            TaskChangesNote(tone: .warn, title: "Stored changes unavailable", detail: "The engine no longer knows this task.")
        case .readRefused(let code):
            TaskChangesNote(tone: .warn, title: "Stored changes unavailable", detail: Self.refusalSentence(code),
                            reason: TaskChangesDisplayText.escaped(code), action: .retryRead)
        case .clientBound:
            TaskChangesNote(tone: .warn, title: "Reading stopped early", detail: Self.clientBoundSentence, action: .retryRead)
        case .unavailable:
            TaskChangesNote(tone: .warn, title: "Changes unavailable",
                            detail: "The engine did not answer. No changes are implied.", action: .retryRead)
        }
    }

    private static func refusalSentence(_ code: String) -> String {
        switch code {
        case TaskChangesRefusalCode.pageTooLarge: "The engine could not fit a page of the stored changes into one answer."
        case TaskChangesRefusalCode.cursorInvalid: "The engine rejected the position this view asked to continue from."
        case TaskChangesRefusalCode.cursorExpired: "The stored changes kept changing while they were read."
        default: "The engine refused this read."
        }
    }
}
