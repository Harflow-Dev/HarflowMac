import Foundation
import MonitorCore

// MARK: - ModelCatalogRepositoryImpl

/// Reads model suggestions per backend from the engine (`harflow-ctl backend-models`). The app starts no
/// harness itself and reads no harness file: tests inject a ctl client with a stub process runner.
public final class ModelCatalogRepositoryImpl: ModelCatalogRepository, Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository
    private let cache = ModelCache()

    public init(toolEnvironment: any ToolEnvironmentRepository) {
        self.toolEnvironment = toolEnvironment
    }

    public func models(for backend: String) async -> [ModelOption] {
        await cache.models(for: backend) { [self] in await fetch(backend) }
    }

    // MARK: Fetching

    /// Only an `available` listing yields options; every other outcome is "no suggestions". While the
    /// managed runtime is preparing or failed there is no ctl client, so the result is empty and, being
    /// empty, is not cached.
    private func fetch(_ backend: String) async -> [ModelOption] {
        guard case .success(let ctl) = toolEnvironment.ctl() else { return [] }
        guard case .listing(let listing) = await ctl.backendModels(backend: backend), listing.state == .available else { return [] }
        return Self.options(from: listing)
    }

    /// One option per engine row, in the engine's order. A label that is empty or shared by several rows
    /// of the same listing cannot tell them apart, so those rows are titled by their id.
    static func options(from listing: BackendModelListing) -> [ModelOption] {
        var labelCounts: [String: Int] = [:]
        for model in listing.models { labelCounts[model.label, default: 0] += 1 }
        return listing.models.map { model in
            let unique = !model.label.isEmpty && labelCounts[model.label] == 1
            return ModelOption(value: model.id, label: unique ? model.label : model.id, effortLevels: model.effortLevels)
        }
    }
}

// MARK: - ModelCache

/// Per-backend cache that also coalesces concurrent requests for the same backend. Empty results are
/// dropped so the next request retries.
private actor ModelCache {
    private var tasks: [String: Task<[ModelOption], Never>] = [:]

    func models(for backend: String, discover: @escaping @Sendable () async -> [ModelOption]) async -> [ModelOption] {
        if let task = tasks[backend] { return await task.value }
        let task = Task { await discover() }
        tasks[backend] = task
        let result = await task.value
        if result.isEmpty { tasks[backend] = nil }
        return result
    }
}
