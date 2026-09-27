//
//  NewSessionVM.swift
//  MainWindowFeature
//

import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import PbUtilities

// MARK: - NewSessionUseCase

/// The New Session sheet's operations over `TaskActionRepository`.
@Mockable
@MainActor
protocol NewSessionUseCase: Sendable {
    /// Expands `~`, then validates the result is an absolute path to an existing directory
    /// (F4-44). Returns the resolved path, or `nil` when the exact validation text
    /// "Choose an existing folder." should be shown.
    func resolvedRepoPath(_ input: String) -> String?

    /// Refreshes the listing before returning, so a caller can route to the new task once this
    /// returns (F4-17) — inherited unchanged from `TaskActionRepository.run`.
    func run(_ request: RunRequest) async throws -> String

    // MARK: Backend catalog (Monitor piece 6)

    var backendCatalog: BackendCatalog { get }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never>
}

// MARK: - NewSessionRouting

/// Navigation and app-shell operations the New Session sheet needs but the VM must not perform
/// itself: `chooseDirectory()` shows an `NSOpenPanel` (AppKit), which belongs in the coordinator
/// (this dispatch's `AGENTS.md`), not the VM.
@Mockable
@MainActor
protocol NewSessionRouting: Sendable {
    func chooseDirectory() async -> String?
    func didStart(taskID: String)
    func dismiss()
}

// MARK: - NewSessionVM

/// View model for the New Session sheet: headless-only. `freedom` defaults to `read_only` with an
/// empty repo/message; a non-blank message and a chosen (non-empty) backend are required to start;
/// success dismisses the sheet, failure stays inline.
///
/// **Agent picker (Monitor piece 6).** `backend`'s default no longer hardcodes `"claude"` — it comes
/// from the backends catalog (`BackendsRepository`, via `NewSessionUseCase`), kept live for as long
/// as the sheet is open (Design's New Session section + Review round 2's selection reconciliation):
/// the previously-selected backend survives a catalog replacement while it's still listed; otherwise
/// selection falls to the catalog's first entry; an empty **successful** catalog (`state == .available`
/// with no entries) clears `backend` and disables Start, so the sheet can never submit a backend it
/// isn't even showing. `PbUI.BackendStyle.known` is used only as New Session's own degraded-mode
/// display fallback (Design: "flagged 'list unavailable'"), while loading and whenever the catalog is
/// degraded with nothing carried over — never as a hardcoded default.
@Observable
@MainActor
final class NewSessionVM: NewSessionViewModel {

    // MARK: - NewSessionViewModel Properties

    private(set) var backend = ""
    private(set) var repo = ""
    private(set) var freedom = "read_only"
    private(set) var message = ""
    private(set) var errorText: String?
    private(set) var isStarting = false
    private(set) var agentOptions: [BackendTab] = []
    /// "<backend> wasn't found on your PATH — starting it may fail." (Review round 2's wording) when
    /// the currently selected backend is a confirmed not-found one; `nil` otherwise.
    private(set) var agentNotFoundNote: String?
    /// "Backend list unavailable — update polybridge." when the catalog is degraded with nothing
    /// carried over, so `agentOptions` is showing the `BackendStyle.known` display fallback rather
    /// than anything polybridge actually reported.
    private(set) var agentListUnavailableNote: String?

    var canStart: Bool {
        !isStarting && !backend.isEmpty && !repo.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Private Properties

    @ObservationIgnored private let useCase: any NewSessionUseCase
    @ObservationIgnored private let routing: any NewSessionRouting
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false

    // MARK: - Init

    init(useCase: any NewSessionUseCase, routing: any NewSessionRouting) {
        self.useCase = useCase
        self.routing = routing
        applyCatalog(useCase.backendCatalog)
    }

    // MARK: - NewSessionViewModel Methods

    func didAppear() {
        subscribeIfNeeded()
    }

    func didDisappear() {
        cancellables.removeAll()
        didSubscribe = false
    }

    func didChangeBackend(_ value: String) {
        backend = value
        recomputeAgentNotFoundNote()
    }

    func didChangeRepo(_ value: String) { repo = value }
    func didChangeFreedom(_ value: String) { freedom = value }
    func didChangeMessage(_ value: String) { message = value }

    func didTapChooseDirectory() {
        Task { [weak self] in
            guard let path = await self?.routing.chooseDirectory() else { return }
            self?.repo = path
        }
    }

    func didTapCancel() {
        routing.dismiss()
    }

    func didTapStart() {
        guard canStart, let path = useCase.resolvedRepoPath(repo) else {
            errorText = "Choose an existing folder."
            return
        }
        errorText = nil

        isStarting = true
        let request = RunRequest(backend: backend, repo: path, prompt: message, freedom: freedom)
        // Capture `useCase`/`routing` strongly before awaiting, so the run completes and routes to
        // the new task even if this VM is torn down first (the sheet was dismissed some other way
        // while the request was in flight) — decision 3/F4-17's "capture Routing strongly" rule.
        // Only the failure path touches `self` (to show the error inline), weakly — there is
        // nothing left to show inline if the VM is already gone.
        let capturedUseCase = useCase
        let capturedRouting = routing
        Task { [weak self] in
            do {
                let id = try await capturedUseCase.run(request)
                // Reset `isStarting` before routing, exactly like the old `NewSessionSheet`'s
                // completion handler always did regardless of outcome — moot for the user (the
                // coordinator dismisses the sheet right after), but keeps the VM's own state
                // consistent for as long as it survives.
                self?.isStarting = false
                capturedRouting.didStart(taskID: id)
            } catch {
                self?.isStarting = false
                self?.errorText = (error as? ToolError)?.message ?? "\(error)"
            }
        }
    }

    // MARK: - Private Methods (Monitor piece 6)

    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        useCase.backendCatalogPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] catalog in self?.applyCatalog(catalog) }
            .store(in: &cancellables)
    }

    /// Review round 2's reconciliation: keep the selected backend while it's still in the new
    /// catalog; otherwise fall to the catalog's first entry — or to nothing at all when the catalog
    /// is empty, which is what disables Start.
    private func applyCatalog(_ catalog: BackendCatalog) {
        let (options, unavailableNote) = Self.computeAgentOptions(from: catalog)
        agentOptions = options
        agentListUnavailableNote = unavailableNote
        if !options.contains(where: { $0.id == backend }) {
            backend = options.first?.id ?? ""
        }
        recomputeAgentNotFoundNote()
    }

    private func recomputeAgentNotFoundNote() {
        guard let option = agentOptions.first(where: { $0.id == backend }), option.isNotFound else {
            agentNotFoundNote = nil
            return
        }
        agentNotFoundNote = "\(backend) wasn't found on your PATH — starting it may fail."
    }

    /// Design's New Session section: every backend polybridge reports, in registry order; while
    /// loading, or when degraded with nothing carried over, falls back to `BackendStyle.known` so
    /// the picker is never empty — flagged with `agentListUnavailableNote` in the degraded case only
    /// (loading is not yet known to be unavailable, so it says nothing).
    private static func computeAgentOptions(from catalog: BackendCatalog) -> (options: [BackendTab], note: String?) {
        switch catalog.state {
        case .available:
            return (catalog.entries.map { BackendTab(id: $0.backend, isNotFound: $0.installed == false) }, nil)
        case .degraded:
            guard catalog.entries.isEmpty else {
                return (catalog.entries.map { BackendTab(id: $0.backend, isNotFound: false) }, nil)
            }
            return (BackendStyle.known.map { BackendTab(id: $0, isNotFound: false) }, "Backend list unavailable — update polybridge.")
        case .loading:
            return (BackendStyle.known.map { BackendTab(id: $0, isNotFound: false) }, nil)
        }
    }
}
