//
//  TaskChangesPresentation.swift
//  MainWindowFeature
//
//  Immutable, `Sendable` models of the Changes tab (HarflowDesign 17739e4, G-DIFF). They are built off the main
//  actor from a stored-changes snapshot and applied to the view model only when they differ from what is shown.
//  They never hold diff or file text: only the escaped names of repositories, paths and provenance.
//

import Foundation
import MonitorCore

// MARK: - TaskChangesTone

/// The ink of a tag or note.
enum TaskChangesTone: Equatable, Sendable {
    case neutral, warn, info
}

// MARK: - TaskChangesTag

/// A small label next to a repository or scope (`.hd-m05-tag`).
struct TaskChangesTag: Equatable, Sendable {
    let text: String
    let tone: TaskChangesTone
}

// MARK: - TaskChangesNote

/// A pane-level note (`.hd-m05-panenote`): a title, an optional detail and reason sentence, and an optional action.
struct TaskChangesNote: Equatable, Sendable {

    /// What the person can do about the note.
    enum Action: Equatable, Sendable {
        /// "Retry read": read the stored changes again from the start.
        case retryRead
        /// "Check again": settling stopped being re-read after its time cap.
        case checkAgain
        /// "Retry": read the selected row's diff again.
        case retryDiff
        /// "Reload changes": the stored changes were replaced, so the list is read again.
        case reloadChanges

        /// The button title.
        var title: String {
            switch self {
            case .retryRead: "Retry read"
            case .checkAgain: "Check again"
            case .retryDiff: "Retry"
            case .reloadChanges: "Reload changes"
            }
        }
    }

    var tone: TaskChangesTone
    var title: String
    var detail: String?
    /// The plain sentence for the reason code, when there is one.
    var reason: String?
    var caption: String?
    /// Placeholder bars drawn under the note; zero draws none.
    var skeletonBars = 0
    var action: Action?
}

// MARK: - TaskChangesFact

/// One provenance term and its escaped value.
struct TaskChangesFact: Equatable, Sendable {
    let term: String
    let value: String
}

// MARK: - TaskChangesScopeID

/// Which scope of which repository of which member task. Reveal limits are keyed by it.
struct TaskChangesScopeID: Hashable, Sendable {
    let taskID: String
    let repository: Int
    /// The scope's wire name.
    let scope: String
}

// MARK: - TaskChangesRowModel

/// One changed path. Not interactive in this stage.
struct TaskChangesRowModel: Equatable, Identifiable, Sendable {
    let id: Int
    /// `M A D T U S ? ·`.
    let letter: String
    /// The status word for assistive technology (escaped when unrecognised).
    let statusWord: String
    /// The escaped path. An untracked directory keeps its trailing `/`.
    let path: String
    /// The row-state label, `nil` for a row whose text is stored in full.
    let state: String?
    /// The reason sentence behind `state`, for help text.
    let stateHelp: String?
    /// `nil` for binary content.
    let additions: Int?
    let deletions: Int?
    /// True when no selector can address the row (cut path, cut repository fields, no root).
    let isDimmed: Bool
    /// The address of the row; `nil` exactly when `isDimmed`.
    var selector: TaskChangesSelector?
}

// MARK: - TaskChangesScopeModel

/// One observation of one repository.
struct TaskChangesScopeModel: Equatable, Identifiable, Sendable {
    let id: TaskChangesScopeID
    let title: String
    /// `3`, `500+`, `1+`, `—`, or `nil` when the scope has no trustworthy count.
    let count: String?
    let tag: TaskChangesTag?
    /// Sentences shown under the heading, in order.
    let captions: [String]
    /// Every stored row of the scope; the view reveals them in steps.
    let rows: [TaskChangesRowModel]
}

// MARK: - TaskChangesRepositoryModel

/// One captured repository.
struct TaskChangesRepositoryModel: Equatable, Identifiable, Sendable {
    let id: Int
    let name: String
    /// The escaped repository root, for help text.
    let help: String?
    let tag: TaskChangesTag?
    /// `nil` for a repository that is not captured, unavailable, not started or unrecognised.
    let count: String?
    let startsOpen: Bool
    /// The engine's fixed non-authorship sentence.
    let attribution: String
    let facts: [TaskChangesFact]
    let notes: [TaskChangesNote]
    let scopes: [TaskChangesScopeModel]
}

// MARK: - TaskChangesDocument

/// A listing with repositories to show.
struct TaskChangesDocument: Equatable, Sendable {
    var banner: TaskChangesNote?
    var repositories: [TaskChangesRepositoryModel]
    /// The complete-capture caption, only for a complete capture of zero rows.
    var caption: String?
    /// "The tab counts rows across repositories and scopes...", for several repositories or a path in both scopes.
    var countCaption: String?
}

// MARK: - TaskChangesPresentation

/// What the Changes tab shows.
enum TaskChangesPresentation: Equatable, Sendable {
    /// No result yet for this read: "Reading stored changes" and a skeleton.
    case loading
    /// A single note in place of a listing.
    case note(TaskChangesNote)
    /// A listing.
    case document(TaskChangesDocument)

    /// "Stored changes aren't available yet" after the settling cadence reached its cap.
    static let settlingCapped = TaskChangesPresentation.note(TaskChangesNote(
        tone: .info, title: "Stored changes aren't available yet",
        detail: "Capture may still be settling. This view stopped checking.", action: .checkAgain))
}

// MARK: - TaskChangesBuilt

/// A presentation with the facts the view model derives from the same result.
struct TaskChangesBuilt: Equatable, Sendable {
    let presentation: TaskChangesPresentation
    /// The approved tab count, `nil` unless the rule holds.
    let tabCount: Int?
    /// True only for a `pending` capture with reason `capture_settling`.
    let isSettling: Bool
    /// True when the read was superseded by a runtime change rather than failed.
    let wasSuperseded: Bool
    /// What selecting a listed row needs, keyed by its selector; empty unless the presentation is a document.
    var rowFacts: [TaskChangesSelector: TaskChangesRowFacts] = [:]
    /// A hash over what a patch depends on: per row its status, counts, content and selector; per repository its base, head,
    /// observation time and state; per scope its state and row count. `0` for a result that is not a listing.
    var fingerprint = 0

    /// Whether the presentation is a listing, the only result that can show a selected row to be absent.
    var isDocument: Bool {
        if case .document = presentation { true } else { false }
    }
}
