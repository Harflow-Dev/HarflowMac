import Foundation
import Mockable
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

    public init(value: String, label: String, effortLevels: [String]? = nil) {
        self.value = value
        self.label = label
        self.effortLevels = effortLevels
    }
}

// MARK: - ModelCatalogRepository

/// The models each agent is known to accept, for the model suggestions of New Session and the workflow
/// editor. The lists come from the engine's advisory `backend-models` read, never from the harnesses
/// directly. Anything that is not an `available` listing (a harness that is not installed, an unavailable
/// source, a refusal, a missing capability, a transport failure, or a runtime that is still preparing)
/// yields an empty list, and the field still lets the user type a model by hand.
///
/// Successful (non-empty) answers are cached per backend for the app's lifetime, including across a
/// managed-runtime upgrade (an app restart clears the cache); an empty answer is never cached, so a
/// later request retries.
@Mockable
public protocol ModelCatalogRepository: Sendable {

    /// The known models for `backend`, in the engine's order, without a "Default" entry. Empty when the
    /// engine offers no suggestions for it: a harness that is not installed or whose source is unavailable,
    /// an unknown backend, or any failure.
    func models(for backend: String) async -> [ModelOption]
}

// MARK: - NullModelCatalogRepository

public struct NullModelCatalogRepository: ModelCatalogRepository {
    public init() {}
    public func models(for _: String) async -> [ModelOption] { [] }
}

// MARK: - GlobalValues

public extension GlobalValues {

    /// Global model-catalog repository.
    @GlobalEntry var modelCatalogRepository: any ModelCatalogRepository = NullModelCatalogRepository()
}
