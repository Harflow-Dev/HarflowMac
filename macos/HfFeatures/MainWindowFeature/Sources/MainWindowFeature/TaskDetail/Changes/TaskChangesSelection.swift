//
//  TaskChangesSelection.swift
//  MainWindowFeature
//
//  The values of the Changes tab's second half: the selected row, the diff drawn for it, and the turn picker.
//  Diff text lives only in `TaskChangesDiffModel`; every type that can hold it describes itself without it.
//

import Foundation
import MonitorCore

// MARK: - TaskChangesSelection

/// A selected row: the member task whose listing holds it and the selector that addresses it (repository root, scope and
/// path bytes). It is the only part of the Changes tab that is persisted, and it holds no diff text.
struct TaskChangesSelection: Equatable, Hashable, Sendable {
    let taskID: String
    let selector: TaskChangesSelector
}

// MARK: - TaskChangesRowFacts

/// What the view model keeps about a listed row to select it: the header, whether text is stored and what to say when it is
/// not. Built with the presentation, off the main actor.
struct TaskChangesRowFacts: Equatable, Sendable {
    let path: String
    let scopeTitle: String
    /// True when the row's content state stores text to read (`available` or `truncated`).
    let hasText: Bool
    /// The row-state label, or a fallback sentence for a selected row that stores no text.
    let label: String?
    let stateHelp: String?
    /// Working tree only: counts and patch are separate observations.
    let countsAndPatchSeparate: Bool
}

// MARK: - TaskChangesDiffHeader

/// `.hd-m05-diffhead`: the escaped path and the scope tag.
struct TaskChangesDiffHeader: Equatable, Sendable {
    let path: String
    let scope: String
}

// MARK: - TaskChangesDiffModel

/// A readable patch. Never printed: the description names only counts. Equality compares the header, the notes and the text's
/// identity (a hash of the patch bytes taken when it was built), never the lines.
struct TaskChangesDiffModel: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let header: TaskChangesDiffHeader
    /// The drawn lines, as one attributed string built off the main actor.
    let text: TaskChangesDiffText
    /// "Bytes, not UTF-8": the text was byte-decoded, never reported as corrupt.
    let notice: String?
    /// "Lines end in CRLF", noted once instead of marking every line.
    let lineEndingNotice: String?
    /// "Stored text ends here · ...", for a truncated patch.
    let tail: String?
    /// The working-tree caption: counts and patch can differ.
    let caption: String?

    var description: String { "TaskChangesDiffModel(\(text.lineCount) lines)" }
    var debugDescription: String { description }
}

// MARK: - TaskChangesDiffPresentation

/// What is drawn under the listing for the selected row.
enum TaskChangesDiffPresentation: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    case none
    /// The row stays selected and no text is implied.
    case loading(TaskChangesDiffHeader)
    /// A selected row that stores no text: its header and label.
    case noText(TaskChangesDiffHeader, label: String)
    case diff(TaskChangesDiffModel)
    case failure(TaskChangesDiffHeader?, TaskChangesNote)

    var description: String {
        switch self {
        case .none: "none"
        case .loading: "loading"
        case .noText: "noText"
        case .diff(let model): "diff(\(model.text.lineCount) lines)"
        case .failure: "failure"
        }
    }

    var debugDescription: String { description }
}

// MARK: - TaskChangesTurnPicker

/// The turn picker (`.hd-m05-turnbar`): shown when the conversation has more than one member.
struct TaskChangesTurnPicker: Equatable, Sendable {
    struct Option: Equatable, Identifiable, Sendable {
        let id: String
        /// "Turn N of M", with " · current" on the newest.
        let title: String
    }

    static let caption = "Each turn is its own task with its own capture. Turns are not added together."

    /// Newest first.
    let options: [Option]
    let selectedID: String
    /// The first 8 characters of the selected task id.
    let shortID: String

    /// Builds the picker for members listed oldest to newest; `nil` unless there is more than one.
    static func make(memberIDs: [String], selectedID: String) -> TaskChangesTurnPicker? {
        guard memberIDs.count > 1 else { return nil }
        let count = memberIDs.count
        let options = memberIDs.enumerated().reversed().map { index, id in
            Option(id: id, title: "Turn \(index + 1) of \(count)" + (index == count - 1 ? " · current" : ""))
        }
        return TaskChangesTurnPicker(options: options, selectedID: selectedID, shortID: String(selectedID.prefix(8)))
    }
}
