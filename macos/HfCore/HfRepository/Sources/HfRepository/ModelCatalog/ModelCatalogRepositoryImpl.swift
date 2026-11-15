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
        let listing = await listing(for: backend)
        return listing.state == .available ? listing.options : []
    }

    public func listing(for backend: String) async -> ModelListing {
        await cache.listing(for: backend) { [self] in await fetch(backend) }
    }

    public func refreshListing(for backend: String) async -> ModelListing {
        await cache.refresh(for: backend) { [self] in await fetch(backend) }
    }

    // MARK: Fetching

    /// Maps every outcome to a listing. While the managed runtime is preparing or failed there is no ctl
    /// client, so the listing is `unreadable`. Rows are kept only for an `available` listing.
    private func fetch(_ backend: String) async -> ModelListing {
        guard case .success(let ctl) = toolEnvironment.ctl() else { return .unreadable }
        guard case .listing(let listing) = await ctl.backendModels(backend: backend) else { return .unreadable }
        return Self.modelListing(from: listing)
    }

    static func modelListing(from listing: BackendModelListing) -> ModelListing {
        let state: ModelListingState = switch listing.state {
        case .available: .available
        case .notInstalled: .notInstalled
        case .unsupported: .unsupported
        case .unavailable: .unavailable(listing.reason)
        case .unrecognized(let wire): .unrecognized(wire)
        }
        return ModelListing(
            state: state, source: listing.source, options: state == .available ? options(from: listing) : [],
            truncated: listing.truncated, droppedCount: listing.droppedCount
        )
    }

    /// One option per engine row, in the engine's order. A label that is empty or shared by several rows
    /// of the same listing cannot tell them apart, so those rows are titled by their id.
    static func options(from listing: BackendModelListing) -> [ModelOption] {
        var labelCounts: [String: Int] = [:]
        for model in listing.models { labelCounts[model.label, default: 0] += 1 }
        return listing.models.map { model in
            let unique = !model.label.isEmpty && labelCounts[model.label] == 1
            return ModelOption(
                value: model.id, label: unique ? model.label : model.id, effortLevels: model.effortLevels,
                isDefault: model.isDefault ?? false
            )
        }
    }
}

// MARK: - ModelCache

/// Per-backend cache that also coalesces concurrent requests for the same backend. Only an `available`
/// listing with rows stays cached; any other answer is dropped when its read finishes, so the next request
/// retries.
///
/// Each entry carries a token. A finishing read may touch the entry only while the stored token is still
/// its own, so a superseded read (replaced by a refresh) never evicts or caches over the newer one. A
/// refresh does not cancel the superseded read: other callers may be sharing it.
private actor ModelCache {

    private struct Entry {
        let token: UUID
        let task: Task<ModelListing, Never>
        let isRefresh: Bool
        var finished = false
    }

    private var entries: [String: Entry] = [:]

    func listing(for backend: String, discover: @escaping @Sendable () async -> ModelListing) async -> ModelListing {
        if let entry = entries[backend] { return await entry.task.value }
        return await install(backend, isRefresh: false, discover: discover).value
    }

    func refresh(for backend: String, discover: @escaping @Sendable () async -> ModelListing) async -> ModelListing {
        if let entry = entries[backend], entry.isRefresh, !entry.finished { return await entry.task.value }
        return await install(backend, isRefresh: true, discover: discover).value
    }

    private func install(
        _ backend: String, isRefresh: Bool, discover: @escaping @Sendable () async -> ModelListing
    ) -> Task<ModelListing, Never> {
        let token = UUID()
        let task = Task {
            let result = await discover()
            await self.finish(backend, token: token, result: result)
            return result
        }
        entries[backend] = Entry(token: token, task: task, isRefresh: isRefresh)
        return task
    }

    private func finish(_ backend: String, token: UUID, result: ModelListing) {
        guard entries[backend]?.token == token else { return }
        if result.state == .available, !result.options.isEmpty {
            entries[backend]?.finished = true
        } else {
            entries[backend] = nil
        }
    }
}
