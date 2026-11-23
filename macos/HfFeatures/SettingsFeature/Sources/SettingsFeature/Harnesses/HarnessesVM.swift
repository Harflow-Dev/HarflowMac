//
//  HarnessesVM.swift
//  SettingsFeature
//
//  Ported from the app target's `SettingsView.swift` (`HarnessSettings`). The confirmation dialog
//  becomes a `ViewEvent.dialog` (decision 10) with identical copy. **Existing issue preserved on
//  purpose**: after a successful action, only that row updates — see `run(_:_:)` below and the
//  settled plan's "Existing issues" section. No `Routing` protocol: this screen has no navigation.
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
    func qualificationBackends() async throws -> [String]
    func status() async -> Result<SetupDocument, ToolError>
    func perform(_ action: SetupClient.Action, client: String?, using setupClient: SetupClient) async -> Result<SetupDocument, ToolError>
    /// Locates `harflow-setup` only, mirroring the original's `model.setup()` pre-check in `run`
    /// (`SettingsView.swift:134`) — checked BEFORE entering the busy (`workingKey`) state, so a
    /// locator failure there is a silent no-op (item 8). `load()`'s own locator failure still shows
    /// through `status()`'s ordinary failure path, unchanged.
    func locate() -> Result<SetupClient, ToolError>

    // MARK: Install (settled plan, section 5)

    /// Emits the current readiness snapshot before subsequent runtime changes.
    func runtimeSetupPublisher() -> AnyPublisher<RuntimeSetupState, Never>
    func installStatePublisher() -> AnyPublisher<InstallState, Never>
    var installState: InstallState { get }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never>
    var lastCheckMessage: String? { get }
    func retry() async
    func reset()
}

// MARK: - HarnessesVM

/// View model for the Harnesses settings tab.
@Observable
@MainActor
final class HarnessesVM: HarnessesViewModel {
    
    // MARK: - HarnessesViewModel Properties
    
    private var qualifications: [String: QualificationPresentation] = [:]
    @ObservationIgnored private var qualificationTask: Task<Void, Never>?
    @ObservationIgnored private var qualificationGeneration = UUID()
    private var qualificationFailure: String?
    var qualificationCards: [QualificationCard] {
        if let qualificationFailure {
            return [.init(id: "discovery", model: .init(identity: "Harness discovery", state: .failed,
                                                        message: qualificationFailure, features: []))]
        }
        return qualifications.keys.sorted().flatMap { backend in
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
        qualifications = [:]
        qualificationFailure = nil
        let generation = UUID()
        qualificationGeneration = generation
        qualificationTask = Task { [weak self, useCase] in
            let backends: [String]
            do { backends = try await useCase.qualificationBackends() } catch {
                guard let self, !Task.isCancelled, generation == qualificationGeneration else { return }
                qualificationFailure = String(((error as? ToolError)?.message ?? String(describing: error)).prefix(1000))
                return
            }
            guard let self, !Task.isCancelled, generation == qualificationGeneration else { return }
            for backend in backends {
                let controller = QualificationPresentation(session: useCase.qualificationSession())
                qualifications[backend] = controller
                _ = await controller.discover(.harness(backend: backend))
                guard !Task.isCancelled, generation == qualificationGeneration else { controller.stop(); return }
            }
        }
    }

    private(set) var rows: [HarnessRow] = []
    private(set) var serverPath: String?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var workingKey: String?
    var isRefreshDisabled: Bool { isLoading || workingKey != nil }
    /// The install/update banner to show where the load-error line shows today, or `nil` when
    /// nothing needs surfacing (settled plan, section 5's precedence rules).
    private(set) var installBannerModel: InstallBanner.Model?

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
    @ObservationIgnored private var installState: InstallState = .idle
    @ObservationIgnored private var lastCheckMessage: String?
    @ObservationIgnored private var latestLoadError: ToolError?

    // MARK: - Init

    init(useCase: any HarnessesUseCase) {
        self.useCase = useCase
        self.installState = useCase.installState
        self.lastCheckMessage = useCase.lastCheckMessage
        recomputeInstallBanner()
    }

    // MARK: - HarnessesViewModel Methods

    func didAppear() {
        loadQualifications()
        subscribeIfNeeded()
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
        loadQualifications()
        Task { [weak self] in await self?.load() }
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

    // MARK: - Install banner actions (settled plan, section 5)

    func didTapInstallBannerPrimary() {
        if case .failed = installState {
            Task { [weak self] in await self?.useCase.retry() }
        }
    }

    func didTapInstallBannerDismiss() {
        useCase.reset()
    }

    // MARK: - Private Methods

    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true

        // The initial snapshot is covered by didAppear's load. Later readiness recovery
        // must refresh even when startup qualification creates no install success notice.
        useCase.runtimeSetupPublisher()
            .receive(on: DispatchQueue.main)
            .map(\.isReady)
            .removeDuplicates()
            .dropFirst()
            .filter(\.self)
            .sink { [weak self] _ in
                self?.loadQualifications()
                Task { [weak self] in await self?.load() }
            }
            .store(in: &cancellables)

        useCase.installStatePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                installState = state
                if state == .installed {
                    // A load error from before the install is stale the moment validation passes —
                    // `install()`'s own validate stage already re-checked both contracts.
                    latestLoadError = nil
                    errorMessage = nil
                }
                recomputeInstallBanner()
            }
            .store(in: &cancellables)

        useCase.lastCheckMessagePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                lastCheckMessage = message
                recomputeInstallBanner()
            }
            .store(in: &cancellables)
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
            errorMessage = nil
            latestLoadError = nil
            isLoading = false
            recomputeInstallBanner()
        case .failure(let failure):
            guard generation == loadGeneration else { return }
            latestLoadError = failure
            errorMessage = failure.isManagedRuntimeUnavailable ? nil : failure.message
            isLoading = false
            recomputeInstallBanner()
        }
    }
    
    /// Existing issue, preserved: only the acted-on row is replaced, not a fresh status for every
    /// row (the old code's comment said otherwise; the code never did that — see `SettingsView.swift`
    /// and the settled plan's "Existing issues, not changed here" section).
    private func run(_ action: SetupClient.Action, _ row: HarnessRow) async {
        // The original's locator check ran BEFORE `working` was set (`SettingsView.swift:134`), so a
        // locator failure never entered the busy state or touched the error line at all — restored
        // here as item 8. Only a failure of the actual `perform` call below sets `errorMessage`.
        guard case .success(let setupClient) = useCase.locate() else { return }
        workingKey = row.key
        defer { workingKey = nil }
        switch await useCase.perform(action, client: row.key, using: setupClient) {
        case .success(let document):
            if let updated = document.rows.first(where: { $0.key == row.key }),
               let index = rows.firstIndex(where: { $0.key == row.key }) {
                rows[index] = updated
            }
            errorMessage = nil
        case .failure(let failure):
            errorMessage = failure.message
        }
        // A failed action is a current tool error, so it must outrank the success banner.
        recomputeInstallBanner()
    }
}

// MARK: - HarnessesVM + Install banner

/// Maps `InstallState` to `InstallBanner.Model`. HfUI can't see `InstallState` (Core doesn't depend
/// on UI), so this mapping lives here — a small, per-feature helper duplicated in `MenuBarVM`.
extension HarnessesVM {

    private func recomputeInstallBanner() {
        switch installState {
        case .running(let stage):
            installBannerModel = InstallBanner.Model(title: Self.runningTitle(stage), detail: Self.runningDetail(stage), isBusy: true)
        case .failed(_, let message):
            installBannerModel = InstallBanner.Model(
                title: "Harflow runtime preparation failed",
                detail: "The managed runtime is unavailable. Try again to prepare it.",
                primaryTitle: "Try again",
                errorText: message,
                canDismiss: true
            )
        case .idle, .installed:
            // A current tool error outranks the success banner: the plain red `errorMessage` shows instead.
            if latestLoadError == nil, installState == .installed, errorMessage == nil {
                installBannerModel = InstallBanner.Model(
                    title: "harflow is installed",
                    detail: "The new install passed its checks.",
                    canDismiss: true,
                    footnote: "Next: register it with your harnesses in Settings → Harnesses."
                )
            } else {
                installBannerModel = nil
            }
        }
    }

    private static func runningTitle(_ stage: InstallStage) -> String {
        if case .validate = stage { return "Checking…" }
        return "Preparing Harflow runtime…"
    }

    private static func runningDetail(_ stage: InstallStage) -> String {
        switch stage {
        case .harflow: "Preparing the exact paired runtime. This can take a few minutes."
        case .validate: "Checking the new install. This can take a little while."
        }
    }
}

extension HarnessesUseCase {
    func qualificationSession() -> QualificationSession { QualificationSession(repository: NullQualificationRepository()) }
    func qualificationBackends() async throws -> [String] { [] }
}
