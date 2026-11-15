//
//  NewSessionVM+ModelListing.swift
//  MainWindowFeature
//

import Foundation
import HfRepository

// MARK: - NewSessionVM + model listing

extension NewSessionVM {

    /// Reads the unavailable listing again. Inert unless the options are unlocked and the loaded listing is
    /// `unavailable`; a second tap while it loads does nothing.
    func didTapRetryModels() {
        guard !optionsLocked, showsModel, case .loaded(let listing) = modelListingPhase, case .unavailable = listing.state else { return }
        startModelLoad(refresh: true)
    }

    /// Requests the current agent's model list without blocking the sheet.
    func loadModels() {
        startModelLoad(refresh: false)
    }

    /// Load and Retry share one task slot and one generation fence. A listing already retained for the
    /// harness is shown at once (with its ranked options) while the read refreshes in the background; only
    /// a harness with nothing retained, or Retry, shows loading. Start gating keeps reading the last applied
    /// options for the same harness, and a harness switch drops the other harness's options.
    private func startModelLoad(refresh: Bool) {
        modelsGeneration += 1
        modelsTask?.cancel()
        modelsTask = nil
        rerankTask?.cancel()
        rerankTask = nil
        let requested = backend
        let generation = modelsGeneration
        guard showsModel else {
            setModelListing(phase: .idle, options: [], backend: "")
            return
        }
        if refresh {
            setModelListing(phase: .loading, options: optionsBackend == requested ? modelOptions : [], backend: requested)
        } else if let kept = retainedListings[requested] {
            setModelListing(phase: .loaded(kept.listing), options: kept.ranked, backend: requested)
        } else {
            setModelListing(phase: .loading, options: optionsBackend == requested ? modelOptions : [], backend: requested)
        }
        modelsTask = Task { [weak self, useCase] in
            let listing = refresh ? await useCase.refreshModelListing(for: requested) : await useCase.modelListing(for: requested)
            guard let self, isCurrentModelLoad(generation, backend: requested) else { return }
            let ranked = await Self.rank(listing.options, backend: requested, usage: useCase.agentUsageSnapshot)
            guard isCurrentModelLoad(generation, backend: requested) else { return }
            retainedListings[requested] = (listing, ranked)
            rerankTask?.cancel()
            rerankTask = nil
            setModelListing(phase: .loaded(listing), options: ranked, backend: requested)
        }
    }

    private func isCurrentModelLoad(_ generation: Int, backend requested: String) -> Bool {
        !Task.isCancelled && generation == modelsGeneration && backend == requested && showsModel
    }

    /// Writes the listing phase and the ranked options only when they changed.
    private func setModelListing(phase: ModelListingPhase, options: [ModelOption], backend: String) {
        if modelListingPhase != phase { modelListingPhase = phase }
        if modelOptions != options { modelOptions = options }
        optionsBackend = backend
    }

    /// A usage change re-ranks the listing already loaded for the chosen harness; the phase is untouched, so
    /// nothing flashes "loading". Dropped when a load or retry starts, or the harness changes, meanwhile.
    func rerankModels() {
        rerankTask?.cancel()
        rerankTask = nil
        let requested = backend
        guard showsModel, let kept = retainedListings[requested] else { return }
        let generation = modelsGeneration
        rerankTask = Task { [weak self, useCase] in
            let ranked = await Self.rank(kept.listing.options, backend: requested, usage: useCase.agentUsageSnapshot)
            await self?.rerankCompletionGate?()
            guard let self, isCurrentModelLoad(generation, backend: requested),
                  retainedListings[requested]?.listing == kept.listing else { return }
            retainedListings[requested] = (kept.listing, ranked)
            if optionsBackend == requested, modelOptions != ranked { modelOptions = ranked }
        }
    }

    /// Ranks off the main actor.
    private nonisolated static func rank(_ options: [ModelOption], backend: String, usage: AgentUsageSnapshot) async -> [ModelOption] {
        await Task.detached { usage.rankedModels(options, backend: backend) }.value
    }
}
