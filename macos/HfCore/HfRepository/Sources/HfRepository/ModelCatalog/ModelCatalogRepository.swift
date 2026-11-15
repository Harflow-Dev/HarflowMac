import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - ModelOption

/// One model an agent can be asked to use: `value` is what `RunRequest.model` carries, `label` is
/// what a picker shows.
public struct ModelOption: Equatable, Hashable, Sendable {
    public let value: String
    public let label: String
    /// The reasoning-effort levels the engine lists as selectable for this model, in the backend's order.
    /// `nil`: the engine says nothing about levels for this model. Empty: it lists levels and none is
    /// selectable.
    public let effortLevels: [String]?
    /// `true` when the engine marks this row as the harness default. `nil` and `false` from the engine
    /// are both `false`.
    public let isDefault: Bool

    public init(value: String, label: String, effortLevels: [String]? = nil, isDefault: Bool = false) {
        self.value = value
        self.label = label
        self.effortLevels = effortLevels
        self.isDefault = isDefault
    }
}

// MARK: - ModelListingState

/// What one `backend-models` read said about a harness. The engine's own states and reasons are reused
/// from MonitorCore; `unreadable` is the app's extra case for a read that produced no listing at all.
public enum ModelListingState: Equatable, Sendable {
    /// The harness listed its models (possibly none).
    case available
    /// The harness is not installed.
    case notInstalled
    /// The harness has no model listing.
    case unsupported
    /// The listing could not be produced; the engine's reason, when it gave one.
    case unavailable(BackendModelListing.Reason?)
    /// A state this app does not know, as the engine reported it.
    case unrecognized(String)
    /// No listing could be read: the capability is missing, the engine refused the caller, the call failed,
    /// or no ctl client exists yet (the runtime is preparing).
    case unreadable
}

// MARK: - ModelListing

/// One harness's model listing: its state, why it is not available when it is not, how complete the
/// rows are, and the rows themselves. `options` is non-empty only for an `available` listing.
public struct ModelListing: Equatable, Sendable {
    public let state: ModelListingState
    /// Where the engine says the rows came from, when it says.
    public let source: BackendModelListing.Source?
    public let options: [ModelOption]
    /// `true` when valid rows were removed by the engine's row or byte cap.
    public let truncated: Bool
    /// Rows the engine dropped as invalid or duplicate; truncated rows are not counted.
    public let droppedCount: Int

    public init(
        state: ModelListingState, source: BackendModelListing.Source? = nil, options: [ModelOption] = [],
        truncated: Bool = false, droppedCount: Int = 0
    ) {
        self.state = state
        self.source = source
        self.options = options
        self.truncated = truncated
        self.droppedCount = droppedCount
    }

    /// The listing of a read that produced nothing.
    public static let unreadable = ModelListing(state: .unreadable)
}

// MARK: - ModelOption + effort

public extension Sequence<ModelOption> {

    /// The effort levels of the suggestion whose value equals `text` exactly (surrounding whitespace
    /// ignored). `nil` when `text` is empty, matches no suggestion, or the suggestion lists no levels.
    func effortLevels(forModel text: String) -> [String]? {
        let chosen = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !chosen.isEmpty else { return nil }
        return first { $0.value == chosen }?.effortLevels
    }
}

// MARK: - ModelCatalogRepository

/// The models each agent is known to accept, for the model suggestions of New Session and the workflow
/// editor. The lists come from the engine's advisory `backend-models` read, never from the harnesses
/// directly. `models(for:)` yields rows only for an `available` listing (a harness that is not installed,
/// an unavailable source, a refusal, a missing capability, a transport failure, or a runtime that is still
/// preparing yield an empty list), and the field still lets the user type a model by hand.
/// `listing(for:)` carries the state behind that empty list.
///
/// An `available` listing with rows is cached per backend for the app's lifetime, including across a
/// managed-runtime upgrade (an app restart clears the cache); every other answer is never cached, so a
/// later request retries.
@Mockable
public protocol ModelCatalogRepository: Sendable {

    /// The known models for `backend`, in the engine's order, without a "Default" entry. Empty when the
    /// engine offers no suggestions for it: a harness that is not installed or whose source is unavailable,
    /// an unknown backend, or any failure.
    func models(for backend: String) async -> [ModelOption]

    /// The listing for `backend`: state, reason source, completeness and rows. Cached and coalesced like
    /// `models(for:)`.
    func listing(for backend: String) async -> ModelListing

    /// Drops the cached answer and any in-flight read for `backend` (the superseded read keeps running for
    /// its own waiters but can no longer touch the cache), then reads again. Concurrent refreshes share one
    /// read.
    func refreshListing(for backend: String) async -> ModelListing
}

// MARK: - NullModelCatalogRepository

public struct NullModelCatalogRepository: ModelCatalogRepository {
    public init() {}
    public func models(for _: String) async -> [ModelOption] { [] }
    public func listing(for _: String) async -> ModelListing { .unreadable }
    public func refreshListing(for _: String) async -> ModelListing { .unreadable }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global model-catalog repository.
    @GlobalEntry var modelCatalogRepository: any ModelCatalogRepository = NullModelCatalogRepository()
}
