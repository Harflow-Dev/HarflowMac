//
//  ModelListingNote.swift
//  MainWindowFeature
//

import HfRepository
import HfUI
import MonitorCore

// MARK: - ModelListingPhase

/// Where the New Session Model field's suggestion listing stands.
enum ModelListingPhase: Equatable, Sendable {
    /// No listing is read: the harness takes no model, or its controls are not known yet.
    case idle
    /// A listing is being read and none is shown for this harness yet, or "Try again" is reading again.
    case loading
    /// The last listing read for the chosen harness.
    case loaded(ModelListing)
}

// MARK: - ModelListingNote

/// The single note under the Model field. The field always accepts free text and the note never blocks
/// Start; it only says why the suggestions are missing or incomplete.
struct ModelListingNote: Equatable, Sendable {
    let text: String
    /// Whether "Try again" is offered under the note (an `unavailable` listing only).
    let showsRetry: Bool

    /// The note for a listing phase, or `nil` when there is nothing to say. First match wins:
    /// 1. the harness takes no model: the per-control message, while the harness list is ready;
    /// 2. the harness is not found: no note here, because the harness popover already says so;
    /// 3. no listing is read (`idle`): no note;
    /// 4. then one note per loading or listing state.
    ///
    /// - Parameter harness: the backend id; the note names the harness by `BackendStyle.displayName`.
    static func make(
        phase: ModelListingPhase, harness: String, controls: BackendControls, catalogReady: Bool, agentNotFound: Bool
    ) -> ModelListingNote? {
        if controls.model == .unsupported {
            return catalogReady ? ModelListingNote(text: "Model selection isn't available for this harness.", showsRetry: false) : nil
        }
        if agentNotFound { return nil }
        switch phase {
        case .idle:
            return nil
        case .loading:
            return plain("Loading suggested models… You can still type a model name.")
        case .loaded(let listing):
            return note(for: listing, name: BackendStyle.displayName(harness))
        }
    }

    // MARK: Listing states

    private static func note(for listing: ModelListing, name: String) -> ModelListingNote? {
        switch listing.state {
        case .notInstalled:
            return plain("\(name) wasn't found on your PATH — starting this harness may fail.")
        case .unavailable(let reason):
            let sentence = reason.flatMap { reasonSentence($0, source: listing.source, name: name) }.map { $0 + " " } ?? ""
            return ModelListingNote(
                text: "Suggested models aren't available. \(sentence)You can still type a model name.", showsRetry: true
            )
        case .available:
            return availableNote(for: listing, name: name)
        case .unsupported:
            return plain("Suggested models aren't available for this harness. You can still type a model name.")
        case .unrecognized, .unreadable:
            return plain("Suggested models aren't available. You can still type a model name.")
        }
    }

    private static func availableNote(for listing: ModelListing, name: String) -> ModelListingNote? {
        if listing.options.isEmpty { return plain("\(name) lists no models. You can still type a model name.") }
        let dropped = listing.droppedCount > 0 ? droppedSentence(listing.droppedCount) : nil
        if listing.truncated {
            let shown = "Showing the first \(listing.options.count) models \(name) listed. You can type a model name that isn't shown."
            return plain([shown, dropped].compactMap(\.self).joined(separator: " "))
        }
        return dropped.map(plain)
    }

    private static func droppedSentence(_ count: Int) -> String {
        count == 1 ? "1 entry was invalid or repeated and was left out." : "\(count) entries were invalid or repeated and were left out."
    }

    /// The reason sentence naming the harness by its display name. `source_missing` is told apart by the
    /// listing's source; an unknown reason has no sentence.
    private static func reasonSentence(_ reason: BackendModelListing.Reason, source: BackendModelListing.Source?, name: String) -> String? {
        switch reason {
        case .sourceMissing:
            switch source {
            case .harnessCache: "\(name)'s model cache wasn't found."
            case .configAliases: "\(name)'s model configuration wasn't found."
            default: "\(name)'s model list wasn't found."
            }
        case .timeout: "\(name) took too long to list its models."
        case .exitNonzero: "\(name) stopped with an error while listing its models."
        case .authRequired: "\(name) needs you to sign in before it can list models."
        case .unparseable: "\(name)'s model list couldn't be read."
        case .outputCeiling: "\(name)'s model list was too long to read."
        case .spawnFailed: "\(name) couldn't be started to list its models."
        case .unrecognized: nil
        }
    }

    private static func plain(_ text: String) -> ModelListingNote { ModelListingNote(text: text, showsRetry: false) }
}
