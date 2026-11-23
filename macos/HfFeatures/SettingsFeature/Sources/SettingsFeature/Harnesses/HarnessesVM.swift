//
//  HarnessesVM.swift
//  SettingsFeature
//
//  Ported from the app target's `SettingsView.swift` (`HarnessSettings`). The confirmation dialog
//  becomes a `ViewEvent.dialog` (decision 10) with identical copy. **Existing issue preserved on
//  purpose**: after a successful action, only that row updates — see `run(_:_:)` below and the
//  settled plan's "Existing issues" section. Its one route is `HarnessesRouting.openSetup()`.
//

import Combine
import Foundation
import HfCommon
import HfRepository
import HfUI
import Mockable
import MonitorCore

// MARK: - HarnessesUseCase

/// `harflow-setup` status/install/remove, straight over `HarnessRepository`.
@Mockable
@MainActor
protocol HarnessesUseCase: Sendable {
    func qualificationSession() -> QualificationSession
    /// The engine catalog's harnesses in catalog order; throws when discovery is unavailable.
    func qualificationBackends() async throws -> [QualificationBackend]
    func status() async -> Result<SetupDocument, ToolError>
    func perform(_ action: SetupClient.Action, client: String?, using setupClient: SetupClient) async -> Result<SetupDocument, ToolError>
    /// Locates `harflow-setup` only, mirroring the original's `model.setup()` pre-check in `run`
    /// (`SettingsView.swift:134`) — checked BEFORE entering the busy (`workingKey`) state, so a
    /// locator failure there is a silent no-op (item 8). `load()`'s own locator failure still shows
    /// through `status()`'s ordinary failure path, unchanged.
    func locate() -> Result<SetupClient, ToolError>

    // MARK: Runtime readiness

    /// The current runtime setup state; the VM seeds its readiness from it.
    var runtimeSetupState: RuntimeSetupState { get }
    /// Emits the current readiness snapshot before subsequent runtime changes.
    func runtimeSetupPublisher() -> AnyPublisher<RuntimeSetupState, Never>
}

// MARK: - HarnessesRouting

/// Where the Harnesses page sends the user when the runtime is not ready.
@Mockable
@MainActor
protocol HarnessesRouting: Sendable {
    /// Shows the main window, whose gate carries the runtime setup.
    func openSetup()
}

// MARK: - HarnessesVM

/// View model for the Harnesses settings tab.
@Observable
@MainActor
final class HarnessesVM: HarnessesViewModel {
    
    // MARK: - HarnessesViewModel Properties
    
    private var qualifications: [String: QualificationPresentation] = [:]
    /// The native harnesses of the catalog, in catalog order.
    private var nativeOrder: [String] = []
    private(set) var qualificationNotes: [QualificationNote] = []
    @ObservationIgnored private var qualificationTask: Task<Void, Never>?
    @ObservationIgnored private var qualificationGeneration = UUID()
    private var qualificationFailure: String?
    var qualificationCards: [QualificationCard] {
        if let qualificationFailure {
            return [.init(id: "discovery", model: .init(identity: "Harness discovery", state: .failed,
                                                        message: qualificationFailure, features: []))]
        }
        return nativeOrder.flatMap { backend in
            (qualifications[backend]?.cards ?? []).map { card in
                QualificationCard(id: backend + ":" + card.id, model: card.model, owner: backend)
            }
        }
    }

    func didTapQualification(_ id: String) {
        if id == "discovery" { loadQualifications(); return }
        guard let backend = qualificationCards.first(where: { $0.id == id })?.owner,
              let controller = qualifications[backend] else { return }
        if controller.isChecking { controller.cancel() } else { controller.check() }
    }

    private func loadQualifications() {
        qualificationTask?.cancel()
        qualifications.values.forEach { $0.stop() }
        resetQualifications()
        let generation = UUID()
        qualificationGeneration = generation
        qualificationTask = Task { [weak self, useCase] in
            let backends: [QualificationBackend]
            do { backends = try await useCase.qualificationBackends() } catch {
                guard let self, !Task.isCancelled, generation == qualificationGeneration else { return }
                qualificationFailure = String(((error as? ToolError)?.message ?? String(describing: error)).prefix(1000))
                return
            }
            guard let self, !Task.isCancelled, generation == qualificationGeneration else { return }
            // Only the native three are discovered or checked; every other harness gets a plain note.
            let native = backends.map(\.backend).filter(NativeQualification.isNative)
            nativeOrder = native
            qualificationNotes = backends.filter { !NativeQualification.isNative($0.backend) }.map(QualificationNote.make(for:))
            for backend in native {
                let controller = QualificationPresentation(session: useCase.qualificationSession())
                qualifications[backend] = controller
                _ = await controller.discover(.harness(backend: backend))
                guard !Task.isCancelled, generation == qualificationGeneration else { controller.stop(); return }
            }
        }
    }

    private(set) var rows: [HarnessRow] = []
    private(set) var serverPath: String?
    private(set) var loadFailure: HarnessLoadFailure?
    private(set) var rowFailures: [String: HarnessRowFailure] = [:]
    private(set) var isLoading = false
    private(set) var workingKey: String?
    /// Seeded from the use case, then follows the runtime setup state. While `false` nothing is loaded.
    private(set) var runtimeReady: Bool
    /// A status load has succeeded since the runtime last became ready.
    private var hasLoaded = false
    var showsRuntimeSetup: Bool { !runtimeReady }
    var showsNoHarnesses: Bool { runtimeReady && !isLoading && hasLoaded && rows.isEmpty && loadFailure == nil }
    var isRefreshDisabled: Bool { !runtimeReady || isLoading || workingKey != nil }

    // MARK: - Private Properties

    @ObservationIgnored private let useCase: any HarnessesUseCase
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    /// Only the latest `load()` call's completion is applied — including the `isLoading` cleanup,
    /// which used to be an unconditional `defer` (a late, stale completion could otherwise clear
    /// `isLoading` out from under a newer, still-in-flight load). Not `private`, for the same
    /// reason `TaskDetailVM.changesGeneration` isn't: `HarnessesVMTests` needs to reach it to
    /// simulate the race Mockable's synchronous `willProduce` can't create directly.
    @ObservationIgnored var loadGeneration = 0
    @ObservationIgnored private let routing: (any HarnessesRouting)?

    // MARK: - Init

    init(useCase: any HarnessesUseCase, routing: (any HarnessesRouting)? = nil) {
        self.useCase = useCase
        self.routing = routing
        self.runtimeReady = useCase.runtimeSetupState.isReady
    }

    // MARK: - HarnessesViewModel Methods

    func didAppear() {
        // A view that reappears may find the runtime changed since it last showed; the subscription's replay then
        // compares equal and does not load a second time.
        setRuntimeReady(useCase.runtimeSetupState.isReady)
        subscribeIfNeeded()
        guard runtimeReady else { return }
        loadQualifications()
        Task { [weak self] in await self?.load() }
    }

    func didDisappear() {
        qualificationGeneration = UUID()
        qualificationTask?.cancel()
        qualifications.values.forEach { $0.stop() }
        cancellables.removeAll()
        didSubscribe = false
    }

    func didTapRefresh() {
        guard runtimeReady else { return }
        loadQualifications()
        Task { [weak self] in await self?.load() }
    }

    func didTapOpenSetup() {
        routing?.openSetup()
    }

    /// Repeats the failed action on the same row, through the same confirmation as the first attempt.
    func didTapRetry(_ row: HarnessRow) {
        guard let failure = rowFailures[row.key] else { return }
        switch failure.action {
        case .install: didTapInstall(row)
        case .remove: didTapRemove(row)
        case .status: break
        }
    }
    
    func didTapInstall(_ row: HarnessRow) {
        let isUpdate = HarnessRowActions.isOutOfDate(row: row)
        publishDialog(
            isUpdate ? "Update harflow in \(row.displayName)?" : "Install harflow into \(row.displayName)?",
            description: "This runs harflow-setup, which edits \(row.displayName)'s own configuration."
        ) {
            AlertAction(title: isUpdate ? "Update" : "Install") { [weak self] in
                Task { await self?.run(.install, row) }
            }
        }
    }
    
    func didTapRemove(_ row: HarnessRow) {
        publishDialog(
            "Remove harflow from \(row.displayName)?",
            description: "This runs harflow-setup, which edits \(row.displayName)'s own configuration."
        ) {
            AlertAction(title: "Remove") { [weak self] in
                Task { await self?.run(.remove, row) }
            }
        }
    }

    // MARK: - Private Methods

    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true

        // The replayed current snapshot equals the seeded value, so it loads nothing. Later recovery loads on the
        // not-ready to ready edge, and a loss of readiness clears the page.
        useCase.runtimeSetupPublisher()
            .receive(on: DispatchQueue.main)
            .map(\.isReady)
            .removeDuplicates()
            .sink { [weak self] isReady in
                guard let self, setRuntimeReady(isReady), isReady else { return }
                loadQualifications()
                Task { [weak self] in await self?.load() }
            }
            .store(in: &cancellables)
    }

    /// Writes readiness only on change and returns whether it changed. Losing readiness drops whatever was loaded
    /// and cancels in-flight work, so a late answer cannot repopulate the not-ready page. Not `private`, for the same
    /// reason as `loadGeneration`: tests change readiness from inside a mocked call, which a publisher cannot do synchronously.
    @discardableResult
    func setRuntimeReady(_ isReady: Bool) -> Bool {
        guard runtimeReady != isReady else { return false }
        runtimeReady = isReady
        if !isReady {
            loadGeneration += 1
            qualificationGeneration = UUID()
            qualificationTask?.cancel()
            qualifications.values.forEach { $0.stop() }
            resetQualifications()
            resetLoaded()
            isLoading = false
            if workingKey != nil { workingKey = nil }
        }
        return true
    }

    /// Drops every qualification card and note, writing only what changes.
    private func resetQualifications() {
        if !qualifications.isEmpty { qualifications = [:] }
        if !nativeOrder.isEmpty { nativeOrder = [] }
        if !qualificationNotes.isEmpty { qualificationNotes = [] }
        if qualificationFailure != nil { qualificationFailure = nil }
    }

    private func resetLoaded() {
        if !rows.isEmpty { rows = [] }
        if serverPath != nil { serverPath = nil }
        if loadFailure != nil { loadFailure = nil }
        if !rowFailures.isEmpty { rowFailures = [:] }
        if hasLoaded { hasLoaded = false }
    }

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        isLoading = true
        switch await useCase.status() {
        case .success(let document):
            guard generation == loadGeneration else { return }
            rows = document.rows
            serverPath = document.serverPath
            if loadFailure != nil { loadFailure = nil }
            if !rowFailures.isEmpty { rowFailures = [:] }
            hasLoaded = true
            isLoading = false
        case .failure(let failure):
            guard generation == loadGeneration else { return }
            resetLoaded()
            // The runtime block owns a managed-runtime failure; every other failure is the refused block.
            if !failure.isManagedRuntimeUnavailable {
                loadFailure = HarnessLoadFailure(message: failure.displayMessage, code: failure.detailCode)
            }
            isLoading = false
        }
    }

    /// Existing issue, preserved: only the acted-on row is replaced, not a fresh status for every
    /// row (the old code's comment said otherwise; the code never did that — see `SettingsView.swift`
    /// and the settled plan's "Existing issues, not changed here" section).
    private func run(_ action: SetupClient.Action, _ row: HarnessRow) async {
        // The original's locator check ran BEFORE `working` was set (`SettingsView.swift:134`), so a
        // locator failure never entered the busy state or touched a failure at all — restored
        // here as item 8. Only a failure of the actual `perform` call below sets the row's failure.
        guard case .success(let setupClient) = useCase.locate() else { return }
        // A readiness change (or a newer load) while the action runs makes its answer stale: it is dropped, and the
        // page's own reset has already cleared the busy key.
        let generation = loadGeneration
        workingKey = row.key
        defer { if generation == loadGeneration { workingKey = nil } }
        if rowFailures[row.key] != nil { rowFailures[row.key] = nil }
        let result = await useCase.perform(action, client: row.key, using: setupClient)
        guard generation == loadGeneration else { return }
        switch result {
        case .success(let document):
            if let updated = document.rows.first(where: { $0.key == row.key }),
               let index = rows.firstIndex(where: { $0.key == row.key }) {
                rows[index] = updated
            }
        case .failure(let failure):
            rowFailures[row.key] = HarnessRowFailure(message: failure.displayMessage, code: failure.detailCode, action: action)
        }
    }
}

extension HarnessesUseCase {
    func qualificationSession() -> QualificationSession { QualificationSession(repository: NullQualificationRepository()) }
    func qualificationBackends() async throws -> [QualificationBackend] { [] }
}
