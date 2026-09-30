import Foundation
import Mockable
import SwiftEnvironment

// MARK: - ModelOption

/// One model an agent can be asked to use: `value` is what `RunRequest.model` carries, `label` is
/// what a picker shows.
public struct ModelOption: Equatable, Hashable, Sendable {
    public let value: String
    public let label: String

    public init(value: String, label: String) {
        self.value = value
        self.label = label
    }
}

// MARK: - ModelCatalogRepository

/// The models each agent is known to accept, for the New Session sheet's model picker. The lists
/// come from the agents themselves (`opencode models`, codex's own model cache) or, for claude, from
/// the aliases its `--help` documents. Discovery never fails loudly: anything that goes wrong yields
/// an empty list, and the picker still lets the user type a model by hand.
///
/// Successful (non-empty) answers are cached per backend for the app's lifetime; an empty answer is
/// never cached, so a later request retries — the agent may simply not have been on `PATH` yet.
@Mockable
public protocol ModelCatalogRepository: Sendable {

    /// The known models for `backend`, in display order, without a "Default" entry. Empty for vibe
    /// (which takes no model), an unknown backend, or any discovery failure.
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
