//
//  TaskChangesPresentationBuilder.swift
//  MainWindowFeature
//
//  A pure function from a read outcome to the Changes tab's presentation. It holds no state and runs off the main
//  actor. Counts, tags and copy follow HarflowDesign 17739e4 (G-DIFF) and decision D-REASONS.
//

import Foundation
import HfRepository
import MonitorCore

// MARK: - TaskChangesReadOutcome

/// What a stored-changes listing read produced.
enum TaskChangesReadOutcome: Equatable, Sendable {
    case snapshot(TaskChangesSnapshot)
    case failure(TaskChangesReadFailure.Outcome)
}

// MARK: - TaskChangesPresentationBuilder

/// Builds the presentation of one read for one member task.
enum TaskChangesPresentationBuilder {

    /// The complete-capture caption under a listing of zero rows.
    static let completeCaption = "Complete capture: every page read, no scope limited, conflicts examined. "
        + "This describes the repository, not what the agent did."
    /// The engine's fixed sentence, which the decoder already requires every repository to carry.
    static let workingTreeCaption = "Includes other writers' and pre-existing changes in this checkout."
    static let noDifferences = "No differences observed."
    static let noRows = "No rows in this scope."
    static let conflictsNotExamined = "No rows in this scope. Conflicts were not examined, so this is not a clean bill."
    /// The most rows a scope shows before "Load more rows".
    static let revealStep = 200

    /// Builds the presentation of `outcome` for the member task `taskID`.
    static func build(taskID: String, outcome: TaskChangesReadOutcome) -> TaskChangesBuilt {
        switch outcome {
        case .failure(let failure):
            guard let classified = TaskChangesFailure.classify(failure) else {
                return TaskChangesBuilt(presentation: .loading, tabCount: nil, isSettling: false, wasSuperseded: true)
            }
            return built(.note(classified.note))
        case .snapshot(let snapshot):
            return build(taskID: taskID, snapshot: snapshot)
        }
    }

    // MARK: - Capture

    private static func build(taskID: String, snapshot: TaskChangesSnapshot) -> TaskChangesBuilt {
        let capture = snapshot.capture
        let reason = capture.reason
        switch capture.state {
        case .pending:
            switch reason {
            case "task_running":
                return built(.note(TaskChangesNote(
                    tone: .info, title: "No changes to show while this runs",
                    detail: "Harflow captures repository differences once, after the task settles.",
                    caption: "Edits the agent reports appear in the transcript. They are not this capture.")))
            case "capture_settling":
                return built(.note(TaskChangesNote(
                    tone: .info, title: "Stored changes aren't available yet",
                    detail: "Capture may still be settling. This view checks again.", skeletonBars: 3)), settling: true)
            default:
                return built(.note(TaskChangesNote(
                    tone: .info, title: "Stored changes aren't available yet", detail: "The capture has not been stored.",
                    reason: TaskChangesReasons.optionalSentence(for: reason))))
            }
        case .notCaptured:
            return built(.note(TaskChangesNote(
                tone: .warn, title: "Changes not captured",
                detail: "The repository may still have changed.", reason: TaskChangesReasons.optionalSentence(for: reason))))
        case .unavailable:
            return built(.note(TaskChangesNote(
                tone: .warn, title: "Stored changes unavailable",
                reason: TaskChangesReasons.optionalSentence(for: reason), action: .retryRead)))
        case .available:
            if reason == "no_repository" {
                return built(.note(TaskChangesNote(
                    tone: .info, title: "No repository recorded", detail: "This task finished without a repository to compare.")))
            }
            guard !snapshot.repositories.isEmpty else {
                return built(.note(TaskChangesNote(
                    tone: .info, title: "No repositories listed", detail: "The stored capture lists no repositories.",
                    reason: TaskChangesReasons.optionalSentence(for: reason))))
            }
            return document(taskID: taskID, snapshot: snapshot, banner: reason.map {
                TaskChangesNote(tone: .info, title: "Capture note", reason: TaskChangesReasons.sentence(for: $0))
            })
        case .incomplete:
            return document(taskID: taskID, snapshot: snapshot, banner: TaskChangesNote(
                tone: .warn, title: "Capture incomplete",
                detail: "Rows read so far are shown, and more may exist. Zero rows here do not mean nothing changed.",
                reason: TaskChangesReasons.optionalSentence(for: reason)))
        default:
            return built(.note(TaskChangesNote(
                tone: .warn, title: "Capture state not recognised",
                reason: TaskChangesReasons.unrecognisedStateText(capture.state.rawValue), action: .retryRead)))
        }
    }

    private static func built(_ presentation: TaskChangesPresentation, settling: Bool = false) -> TaskChangesBuilt {
        TaskChangesBuilt(presentation: presentation, tabCount: nil, isSettling: settling, wasSuperseded: false)
    }

    // MARK: - Document

    private static func document(taskID: String, snapshot: TaskChangesSnapshot, banner: TaskChangesNote?) -> TaskChangesBuilt {
        let names = repositoryNames(snapshot.repositories)
        let repositories = snapshot.repositories.enumerated().map { index, entry in
            repository(taskID: taskID, index: index, name: names[index], entry: entry)
        }
        let document = TaskChangesDocument(banner: banner, repositories: repositories,
                                           caption: snapshot.hasNoChanges ? completeCaption : nil,
                                           countCaption: needsCountCaption(snapshot) ? countCaption : nil)
        return TaskChangesBuilt(presentation: .document(document), tabCount: tabCount(snapshot), isSettling: false, wasSuperseded: false,
                                rowFacts: rowFacts(snapshot), fingerprint: fingerprint(snapshot))
    }

    /// The fingerprint of a listing; see `TaskChangesBuilt.fingerprint`. Process-local, so it is only compared within a run.
    static func fingerprint(_ snapshot: TaskChangesSnapshot) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot.taskID)
        for entry in snapshot.repositories {
            hasher.combine(entry.baseCommit)
            hasher.combine(entry.headCommit)
            hasher.combine(entry.observedAt)
            hasher.combine(entry.state.rawValue)
            for scope in entry.scopes {
                hasher.combine(scope.name.rawValue)
                hasher.combine(scope.state.rawValue)
                hasher.combine(scope.rowCount)
                for row in scope.rows {
                    hasher.combine(row.status.rawValue)
                    hasher.combine(row.additions)
                    hasher.combine(row.deletions)
                    hasher.combine(row.content.state.rawValue)
                    hasher.combine(row.content.reason)
                    hasher.combine(row.content.bytes)
                    hasher.combine(TaskChangesSelector(repository: entry, scope: scope.name, row: row))
                    hasher.combine(row.path.bytes)
                }
            }
        }
        return hasher.finalize()
    }

    /// The facts of every addressable row, for selecting it.
    private static func rowFacts(_ snapshot: TaskChangesSnapshot) -> [TaskChangesSelector: TaskChangesRowFacts] {
        var facts: [TaskChangesSelector: TaskChangesRowFacts] = [:]
        for entry in snapshot.repositories where entry.state == .available || entry.state == .incomplete {
            for scope in entry.scopes {
                for row in scope.rows {
                    guard let selector = TaskChangesSelector(repository: entry, scope: scope.name, row: row) else { continue }
                    let state = rowState(row)
                    facts[selector] = TaskChangesRowFacts(
                        path: TaskChangesDisplayText.escaped(row.path), scopeTitle: scopeTitle(scope.name),
                        hasText: [TaskChangesContentState.available, .truncated].contains(row.content.state), label: state.label,
                        stateHelp: state.help, countsAndPatchSeparate: scope.countsAndPatchSeparate == true)
                }
            }
        }
        return facts
    }

    /// Under a listing of several repositories, or of a path in both scopes of one.
    static let countCaption = "The tab counts rows across repositories and scopes. A path in both scopes counts twice."

    private static func needsCountCaption(_ snapshot: TaskChangesSnapshot) -> Bool {
        if snapshot.repositories.count > 1 { return true }
        return snapshot.repositories.contains { entry in
            let paths = entry.scopes.map { Set($0.rows.map(\.path.bytes)) }
            return paths.count > 1 && !paths[0].isDisjoint(with: paths[1])
        }
    }

    /// The approved rule: the sum of stored `row_count`, only for an available capture of at least one repository in
    /// which every repository and scope is available and no scope truncated its rows. It never uses `isComplete`.
    static func tabCount(_ snapshot: TaskChangesSnapshot) -> Int? {
        guard snapshot.capture.state == .available, !snapshot.repositories.isEmpty else { return nil }
        var total = 0
        for entry in snapshot.repositories {
            guard entry.state == .available else { return nil }
            for scope in entry.scopes {
                guard scope.state == .available, !scope.rowsTruncated else { return nil }
                total += scope.rowCount
            }
        }
        return total
    }

    // MARK: - Repository

    private static func repository(taskID: String, index: Int, name: String, entry: TaskChangesRepositoryEntry) -> TaskChangesRepositoryModel {
        let showsScopes = entry.state == .available || entry.state == .incomplete
        let scopes = showsScopes ? entry.scopes.map { scope(taskID: taskID, index: index, entry: entry, scope: $0) } : []
        let hasUnmerged = showsScopes && entry.scopes.contains { $0.unmergedUnknown == true }
        let reported = showsScopes ? entry.scopes.compactMap(\.reportedConflicts).filter { !$0.isEmpty } : []
        var notes: [TaskChangesNote] = []
        if entry.state != .available {
            notes.append(stateNote(entry))
        }
        if hasUnmerged {
            notes.append(TaskChangesNote(tone: .warn, title: "Conflicts may exist",
                                         detail: "Conflict names could not be read from this checkout. The rows above are still the real diff."))
        }
        if !reported.isEmpty {
            notes.append(TaskChangesNote(
                tone: .info, title: "Conflicts may exist",
                detail: "The agent's index reports conflicted names. They are advisory and never add, change or hide a row."))
        }
        return TaskChangesRepositoryModel(
            id: index, name: name, help: entry.repositoryRoot.map(TaskChangesDisplayText.escaped), tag: repositoryTag(entry),
            count: repositoryCount(entry), startsOpen: index == 0, attribution: TaskChangesRepositoryEntry.attribution,
            facts: facts(entry), notes: notes, scopes: scopes)
    }

    /// The repository-level sentence for a state other than `available`, drawn as a neutral caption.
    private static func stateNote(_ entry: TaskChangesRepositoryEntry) -> TaskChangesNote {
        switch entry.state {
        case .incomplete, .unavailable, .notCaptured:
            TaskChangesNote(tone: .neutral, title: TaskChangesReasons.optionalSentence(for: entry.reason) ?? "No reason was given.")
        default:
            TaskChangesNote(tone: .warn, title: TaskChangesReasons.unrecognisedStateText(entry.state.rawValue))
        }
    }

    private static func repositoryTag(_ entry: TaskChangesRepositoryEntry) -> TaskChangesTag? {
        switch entry.state {
        case .available:
            return availableTag(entry)
        case .incomplete:
            if entry.reason == "budget_exhausted" { return TaskChangesTag(text: "Not started · budget used", tone: .warn) }
            return TaskChangesTag(text: "Incomplete", tone: .warn)
        case .unavailable:
            return TaskChangesTag(text: "Unavailable", tone: .warn)
        case .notCaptured:
            switch entry.reason {
            case "repository_identity_changed": return TaskChangesTag(text: "Identity changed", tone: .warn)
            case "alternates_present": return TaskChangesTag(text: "Alternates present", tone: .warn)
            case "object_store_untrusted": return TaskChangesTag(text: "Object store untrusted", tone: .warn)
            default: return TaskChangesTag(text: "Not captured", tone: .warn)
            }
        default:
            return TaskChangesTag(text: TaskChangesDisplayText.escaped(entry.state.rawValue), tone: .warn)
        }
    }

    private static func availableTag(_ entry: TaskChangesRepositoryEntry) -> TaskChangesTag? {
        if entry.scopes.contains(where: \.rowsTruncated) { return TaskChangesTag(text: "Row limit", tone: .warn) }
        if let missing = entry.scopes.first(where: { $0.state == .notCaptured }) {
            return TaskChangesTag(text: "\(scopeTitle(missing.name)) not captured", tone: .warn)
        }
        if entry.scopes.contains(where: { $0.state != .available }) { return TaskChangesTag(text: "Incomplete", tone: .warn) }
        if entry.scopes.contains(where: { $0.unmergedUnknown == true }) { return TaskChangesTag(text: "Conflicts unknown", tone: .warn) }
        if entry.scopes.contains(where: { !($0.reportedConflicts?.isEmpty ?? true) }) {
            return TaskChangesTag(text: "Reported conflict", tone: .info)
        }
        return nil
    }

    /// The sum of the scope counts, with `+` when any scope count has one or the repository is incomplete. `nil`
    /// for a repository that is not captured, unavailable, not started or in an unrecognised state.
    private static func repositoryCount(_ entry: TaskChangesRepositoryEntry) -> String? {
        switch entry.state {
        case .available: break
        case .incomplete: if entry.reason == "budget_exhausted" { return nil }
        default: return nil
        }
        var total = 0
        var plus = entry.state == .incomplete
        for scope in entry.scopes {
            guard let parts = scopeCount(scope, inIncompleteRepository: entry.state == .incomplete) else { continue }
            total += parts.value
            plus = plus || parts.plus
        }
        return "\(total)" + (plus ? "+" : "")
    }

    private static func facts(_ entry: TaskChangesRepositoryEntry) -> [TaskChangesFact] {
        var facts: [TaskChangesFact] = []
        let base = [entry.baseCommit.map { String($0.prefix(7)) }, entry.baseProvenance].compactMap(\.self)
        if !base.isEmpty { facts.append(TaskChangesFact(term: "Base", value: TaskChangesDisplayText.escaped(base.joined(separator: " · ")))) }
        if let head = entry.headCommit {
            facts.append(TaskChangesFact(term: "Head", value: TaskChangesDisplayText.escaped(String(head.prefix(7)))))
        }
        if let worktree = entry.worktree { facts.append(TaskChangesFact(term: "Working tree", value: TaskChangesDisplayText.escaped(worktree))) }
        if let observed = entry.observedAt { facts.append(TaskChangesFact(term: "Observed", value: observedText(observed))) }
        let dirty: String = switch entry.baselineDirty {
        case .dirty: "Yes"
        case .clean: "No"
        case .unknown: "Unknown"
        case .other(let raw): TaskChangesDisplayText.escaped(raw)
        }
        facts.append(TaskChangesFact(term: "Started dirty", value: dirty))
        if entry.fieldsTruncated { facts.append(TaskChangesFact(term: "Note", value: "Some of these values were cut.")) }
        return facts
    }

    /// An ISO 8601 time as the person's locale writes it; anything else, escaped as it came.
    static func observedText(_ raw: String) -> String {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = plain.date(from: raw) ?? fractional.date(from: raw) else { return TaskChangesDisplayText.escaped(raw) }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Names

    /// Escaped last path component of each root; "Repository N" without a root, a trailing "…" when the root is cut
    /// and the last two components when names repeat.
    static func repositoryNames(_ entries: [TaskChangesRepositoryEntry]) -> [String] {
        let components = entries.map { entry in entry.repositoryRoot.map { $0.split(separator: "/", omittingEmptySubsequences: true).map(String.init) } }
        let lastNames = components.map { $0?.last }
        return entries.indices.map { index in
            guard let parts = components[index], let root = entries[index].repositoryRoot else { return "Repository \(index + 1)" }
            var name = parts.last ?? root
            let repeated = lastNames.indices.contains { $0 != index && lastNames[$0] == lastNames[index] && components[$0] != nil }
            if repeated, parts.count > 1 { name = parts.suffix(2).joined(separator: "/") }
            let escaped = TaskChangesDisplayText.escaped(name)
            return entries[index].fieldsTruncated && rootWasCut(root) ? escaped + "…" : escaped
        }
    }

    /// A heuristic for whether the root itself was cut by the engine: its JSON-escaped form is within one character of
    /// the 4096 byte bound. It is only consulted when `fields_truncated` is set; an intact root near the bound with another
    /// field cut is indistinguishable, and the provenance note states that fields were cut. The size count mirrors
    /// MonitorCore's internal `TaskChangesFields.escapedBytes` (JSON with `ensure_ascii`); keep the two in step.
    private static func rootWasCut(_ root: String) -> Bool {
        let escaped = root.unicodeScalars.reduce(0) { total, scalar in
            switch scalar.value {
            case 0x22, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D: total + 2
            case 0 ..< 0x20, 0x7F: total + 6
            case 0x20 ..< 0x7F: total + 1
            case 0x80 ... 0xFFFF: total + 6
            default: total + 12
            }
        }
        return escaped > TaskChangesLimits.maxFieldEscapedBytes - 12
    }

    // MARK: - Scope

    private static func scopeTitle(_ name: TaskChangesScopeName) -> String {
        switch name {
        case .committedRange: "Committed"
        case .workingTree: "Working tree"
        default: TaskChangesDisplayText.escaped(name.rawValue)
        }
    }

    /// A scope count: its `row_count`, with `+` when the rows are truncated or the scope is incomplete (`0+` when it has no
    /// rows). `nil` for a scope with no trustworthy count.
    private static func scopeCount(_ scope: TaskChangesScope, inIncompleteRepository: Bool = false) -> (value: Int, plus: Bool)? {
        switch scope.state {
        case .available: (scope.rowCount, scope.rowsTruncated || inIncompleteRepository)
        case .incomplete: (scope.rowCount, true)
        default: nil
        }
    }

    private static func scopeCountText(_ scope: TaskChangesScope, inIncompleteRepository: Bool) -> String? {
        if scope.state == .notCaptured { return "—" }
        return scopeCount(scope, inIncompleteRepository: inIncompleteRepository).map { "\($0.value)" + ($0.plus ? "+" : "") }
    }

    /// True when the repository is available, both scopes are present and available, nothing is truncated and no
    /// conflicts are unexamined.
    private static func isComplete(_ entry: TaskChangesRepositoryEntry) -> Bool {
        guard entry.state == .available, entry.scope(.committedRange) != nil, entry.scope(.workingTree) != nil else { return false }
        return entry.scopes.allSatisfy { $0.state == .available && !$0.rowsTruncated && $0.unmergedUnknown != true }
    }

    private static func scope(taskID: String, index: Int, entry: TaskChangesRepositoryEntry, scope: TaskChangesScope) -> TaskChangesScopeModel {
        let id = TaskChangesScopeID(taskID: taskID, repository: index, scope: scope.name.rawValue)
        var captions: [String] = []
        if scope.state != .available, let reason = scope.reason { captions.append(TaskChangesReasons.sentence(for: reason)) }
        if scope.state != .available, scope.reason == nil, ![.notCaptured, .incomplete, .unavailable].contains(scope.state) {
            captions.append(TaskChangesReasons.unrecognisedStateText(scope.state.rawValue))
        }
        if scope.name == .workingTree, !scope.rows.isEmpty {
            captions.append(workingTreeCaption + (entry.baselineDirty == .dirty ? " It was already dirty when this task started." : ""))
        }
        if scope.state == .available, scope.rowCount == 0, scope.rows.isEmpty {
            let hasNames = entry.scopes.contains { !($0.reportedConflicts?.isEmpty ?? true) }
            if scope.unmergedUnknown == true {
                captions.append(conflictsNotExamined)
            } else if isComplete(entry), !hasNames {
                captions.append(noDifferences)
            } else {
                captions.append(noRows)
            }
        }
        let rows = scope.rows.enumerated().map { rowIndex, row in
            self.row(index: rowIndex, entry: entry, scope: scope, row: row)
        }
        let count = scopeCountText(scope, inIncompleteRepository: entry.state == .incomplete)
        return TaskChangesScopeModel(id: id, title: scopeTitle(scope.name), count: count, tag: scopeTag(scope), captions: captions, rows: rows)
    }

    private static func scopeTag(_ scope: TaskChangesScope) -> TaskChangesTag? {
        if scope.rowsTruncated { return TaskChangesTag(text: "Row limit · \(scope.rowCount) of more", tone: .warn) }
        switch scope.state {
        case .available: break
        case .incomplete:
            switch scope.reason {
            case "capture_timeout": return TaskChangesTag(text: "Incomplete · time limit", tone: .warn)
            case "output_ceiling": return TaskChangesTag(text: "Incomplete · output limit", tone: .warn)
            default: return TaskChangesTag(text: "Incomplete", tone: .warn)
            }
        case .notCaptured: return TaskChangesTag(text: "Not captured", tone: .warn)
        case .unavailable: return TaskChangesTag(text: "Unavailable", tone: .warn)
        default: return TaskChangesTag(text: TaskChangesDisplayText.escaped(scope.state.rawValue), tone: .warn)
        }
        if scope.unmergedUnknown == true { return TaskChangesTag(text: "Conflicts unknown", tone: .warn) }
        if !(scope.reportedConflicts?.isEmpty ?? true) { return TaskChangesTag(text: "Reported conflict", tone: .info) }
        return nil
    }

    // MARK: - Row

    private static func row(index: Int, entry: TaskChangesRepositoryEntry, scope: TaskChangesScope, row: TaskChangesRow) -> TaskChangesRowModel {
        let (letter, word) = status(row.status)
        let (state, help) = rowState(row)
        let selector = TaskChangesSelector(repository: entry, scope: scope.name, row: row)
        let knownContent = [TaskChangesContentState.available, .truncated, .binary, .omittedSize, .notCaptured].contains(row.content.state)
        return TaskChangesRowModel(
            id: index, letter: letter, statusWord: word, path: TaskChangesDisplayText.escaped(row.path), state: state, stateHelp: help,
            additions: knownContent ? row.additions : nil, deletions: knownContent ? row.deletions : nil,
            isDimmed: selector == nil, selector: selector)
    }

    /// The status letter and the word read aloud.
    static func status(_ status: TaskChangesRowStatus) -> (String, String) {
        let letter = switch status {
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .typechange: "T"
        case .unmerged: "U"
        case .submodule: "S"
        case .untracked: "?"
        default: "·"
        }
        return (letter, TaskChangesDisplayText.escaped(status.rawValue))
    }

    /// The row-state label and its help sentence; `nil` label for a row whose text is stored in full.
    static func rowState(_ row: TaskChangesRow) -> (label: String?, help: String?) {
        if row.pathTruncated { return ("Path cut · no text", TaskChangesReasons.sentence(for: "path_too_long")) }
        let content = row.content
        let reason = content.reason
        let help = TaskChangesReasons.rowSentence(state: content.state.rawValue, reason: reason)
        switch content.state {
        case .available:
            return (row.path.utf8String == nil ? "Bytes, not UTF-8" : nil, nil)
        case .truncated:
            switch reason {
            case "file_limit": return ("Truncated · over 64 KiB", help)
            case "task_limit": return ("Partial text · task limit", help)
            case "capture_timeout", "output_ceiling": return ("Truncated · time or output limit", help)
            default: return ("Truncated", help)
            }
        case .omittedSize:
            return ("Text omitted · task limit", help)
        case .binary:
            return ("Binary", help)
        case .notCaptured:
            switch reason {
            case "untracked": return (row.path.bytes.last == UInt8(ascii: "/") ? "Directory · name only" : "Name only", help)
            case "submodule": return ("Submodule · no text", help)
            case "unmerged": return ("Unmerged · no text", help)
            case "path_too_long": return ("Path cut · no text", help)
            default: return ("Not captured", help)
            }
        default:
            return (TaskChangesDisplayText.escaped(content.state.rawValue), TaskChangesReasons.unrecognisedState)
        }
    }
}
