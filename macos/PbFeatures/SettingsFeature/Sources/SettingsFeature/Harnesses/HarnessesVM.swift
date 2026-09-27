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
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI

// MARK: - HarnessesUseCase

/// `polybridge-setup` status/install/remove, straight over `HarnessRepository`.
@Mockable
@MainActor
protocol HarnessesUseCase: Sendable {
    func status() async -> Result<SetupDocument, ToolError>
    func perform(_ action: SetupClient.Action, client: String?, using setupClient: SetupClient) async -> Result<SetupDocument, ToolError>
    /// Locates `polybridge-setup` only, mirroring the original's `model.setup()` pre-check in `run`
    /// (`SettingsView.swift:134`) — checked BEFORE entering the busy (`workingKey`) state, so a
    /// locator failure there is a silent no-op (item 8). `load()`'s own locator failure still shows
    /// through `status()`'s ordinary failure path, unchanged.
    func locate() -> Result<SetupClient, ToolError>

    // MARK: Install (settled plan, section 5)

    func installStatePublisher() -> AnyPublisher<InstallState, Never>
    var installState: InstallState { get }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never>
    var lastCheckMessage: String? { get }
    func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never>
    var installAnywayBlockedMessage: String? { get }
    /// Classifies `error` against the currently located `polybridge-ctl`/`polybridge-setup`
    /// presence; `nil` when `error` isn't an install need.
    func installNeed(for error: ToolError) -> InstallNeed?
    /// Where the next install would land, for confirmation-dialog copy only.
    func installDestination() -> String?
    func install() async
    func installUvThenPolybridge() async
    func retry() async
    func checkAgain() async
    @discardableResult
    func installAnyway() async -> Bool
    func reset()
}

// MARK: - HarnessesVM

/// View model for the Harnesses settings tab.
@Observable
@MainActor
final class HarnessesVM: HarnessesViewModel {
    
    // MARK: - HarnessesViewModel Properties
    
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
    @ObservationIgnored private var installAnywayBlockedMessage: String?
    @ObservationIgnored private var latestLoadError: ToolError?
    @ObservationIgnored private var currentInstallNeed: InstallNeed?

    // MARK: - Init

    init(useCase: any HarnessesUseCase) {
        self.useCase = useCase
        self.installState = useCase.installState
        self.lastCheckMessage = useCase.lastCheckMessage
        self.installAnywayBlockedMessage = useCase.installAnywayBlockedMessage
        recomputeInstallBanner()
    }

    // MARK: - HarnessesViewModel Methods

    func didAppear() {
        subscribeIfNeeded()
        Task { [weak self] in await self?.load() }
    }

    func didDisappear() {
        cancellables.removeAll()
        didSubscribe = false
    }

    func didTapRefresh() {
        Task { [weak self] in await self?.load() }
    }
    
    func didTapInstall(_ row: HarnessRow) {
        publishDialog(
            "Install polybridge into \(row.displayName)?",
            description: "This runs polybridge-setup, which edits \(row.displayName)'s own configuration."
        ) {
            AlertAction(title: "Install") { [weak self] in
                Task { await self?.run(.install, row) }
            }
        }
    }
    
    func didTapRemove(_ row: HarnessRow) {
        publishDialog(
            "Remove polybridge from \(row.displayName)?",
            description: "This runs polybridge-setup, which edits \(row.displayName)'s own configuration."
        ) {
            AlertAction(title: "Remove") { [weak self] in
                Task { await self?.run(.remove, row) }
            }
        }
    }

    // MARK: - Install banner actions (settled plan, section 5)

    func didTapInstallBannerPrimary() {
        switch installState {
        case .needsGit:
            Task { [weak self] in await self?.useCase.install() }
        case .needsUv:
            publishInstallUvDialog()
        case .failed:
            Task { [weak self] in await self?.useCase.retry() }
        case .unresolved:
            Task { [weak self] in await self?.useCase.checkAgain() }
        case .running:
            break
        case .idle, .installed:
            if let need = currentInstallNeed { publishInstallOrUpdateDialog(need: need) }
        }
    }

    func didTapInstallBannerSecondary() {
        if case .unresolved = installState { publishInstallAnywayDialog() }
    }

    func didTapInstallBannerDismiss() {
        useCase.reset()
    }

    // MARK: - Private Methods

    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true

        useCase.installStatePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                let wasInstalled = installState == .installed
                installState = state
                if state == .installed {
                    // A load error from before the install is stale the moment validation passes —
                    // `install()`'s own validate stage already re-checked both contracts.
                    latestLoadError = nil
                    currentInstallNeed = nil
                    errorMessage = nil
                }
                recomputeInstallBanner()
                // Settled plan: reload once installation completes, so the table picks up the
                // freshly-registered `polybridge-ctl`/`polybridge-setup` without a manual refresh.
                if !wasInstalled, state == .installed {
                    Task { [weak self] in await self?.load() }
                }
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

        useCase.installAnywayBlockedMessagePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                installAnywayBlockedMessage = message
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
            currentInstallNeed = nil
            isLoading = false
            recomputeInstallBanner()
        case .failure(let failure):
            guard generation == loadGeneration else { return }
            latestLoadError = failure
            currentInstallNeed = useCase.installNeed(for: failure)
            errorMessage = currentInstallNeed == nil ? failure.message : nil
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

// MARK: - HarnessesVM + Install banner (settled plan, section 5)

/// Maps `InstallState`/`InstallNeed` to `InstallBanner.Model` and the three confirmation dialogs.
/// PbUI can't see `InstallState` (Core doesn't depend on UI), so this mapping lives here — a small,
/// per-feature helper duplicated in `SidebarVM`/`MenuBarVM`, not shared, per the settled plan.
extension HarnessesVM {

    private func recomputeInstallBanner() {
        switch installState {
        case .needsGit:
            installBannerModel = InstallBanner.Model(
                title: "git is needed to install polybridge",
                detail: "Install Apple's Command Line Tools first (`xcode-select --install`), then try again.",
                primaryTitle: "Try again"
            )
        case .needsUv:
            installBannerModel = InstallBanner.Model(
                title: "uv is needed to install polybridge",
                detail: "polybridge is installed with uv, which wasn't found.",
                primaryTitle: "Install uv"
            )
        case .running(let stage):
            installBannerModel = InstallBanner.Model(title: Self.runningTitle(stage), detail: Self.runningDetail(stage), isBusy: true)
        case .failed(_, let message):
            installBannerModel = InstallBanner.Model(
                title: "polybridge couldn't be installed",
                detail: "Something went wrong while installing.",
                primaryTitle: "Try again",
                errorText: message,
                canDismiss: true
            )
        case .unresolved:
            installBannerModel = InstallBanner.Model(
                title: "The install may still be running",
                detail: "It didn't finish in time and may still be working in the background. Check again once it has finished.",
                primaryTitle: "Check again",
                secondaryTitle: "Install anyway",
                errorText: installAnywayBlockedMessage ?? lastCheckMessage
            )
        case .idle, .installed:
            if let need = currentInstallNeed, let error = latestLoadError {
                installBannerModel = InstallBanner.Model(
                    title: need == .missing ? "polybridge isn't installed" : "polybridge is incomplete or out of date",
                    detail: error.message,
                    primaryTitle: need == .missing ? "Install polybridge" : "Update polybridge"
                )
            } else if latestLoadError != nil {
                // A current tool error that isn't an install need still outranks the success
                // banner (R2-2) — the plain red `errorMessage` shows instead, banner-free.
                installBannerModel = nil
            } else if installState == .installed, errorMessage == nil {
                installBannerModel = InstallBanner.Model(
                    title: "polybridge is installed",
                    detail: "The new install passed its checks.",
                    canDismiss: true,
                    footnote: "Next: register it with your agents in Settings → Harnesses."
                )
            } else {
                installBannerModel = nil
            }
        }
    }

    private static func runningTitle(_ stage: InstallStage) -> String {
        if case .validate = stage { return "Checking…" }
        return "Installing polybridge…"
    }

    private static func runningDetail(_ stage: InstallStage) -> String {
        switch stage {
        case .git: "Checking for git…"
        case .uv: "Setting up uv…"
        case .polybridge: "Installing polybridge from GitHub. This can take a few minutes."
        case .validate: "Checking the new install. This can take a little while."
        }
    }

    private func destinationLine() -> String {
        if let destination = useCase.installDestination() { "\n\nInstalls into \(destination)." } else {
            "\n\nInstalls into uv's tool folder, once uv is found."
        }
    }

    private func publishInstallOrUpdateDialog(need: InstallNeed) {
        let isMissing = need == .missing
        let message = "This replaces the polybridge installation used by agent sessions. Existing sessions may be disrupted "
            + "or fail on later operations. Finish running tasks and close sessions using polybridge before continuing. "
            + "polybridge will be installed from GitHub with uv." + destinationLine()
        publishDialog(isMissing ? "Install polybridge?" : "Update polybridge?", description: message) {
            AlertAction(title: isMissing ? "Install" : "Update") { [weak self] in self?.confirmInstallOrUpdate() }
        }
    }

    private func publishInstallUvDialog() {
        publishDialog(
            "Install uv?",
            description: "uv is needed to install polybridge. Install it now with astral's official installer? "
                + "This downloads and runs https://astral.sh/uv/install.sh, then installs polybridge."
        ) {
            AlertAction(title: "Install uv") { [weak self] in self?.confirmInstallUv() }
        }
    }

    private func publishInstallAnywayDialog() {
        let message = "An earlier install may still be finishing. Only continue if you're sure it has stopped." + destinationLine()
        publishDialog("Install anyway?", description: message) {
            AlertAction(title: "Install anyway") { [weak self] in self?.confirmInstallAnyway() }
        }
    }

    /// Stale-confirm guard: re-checks the *current* state before acting, since the state can change
    /// between the dialog publishing and the person confirming it.
    private func confirmInstallOrUpdate() {
        guard Self.stateAllowsInstall(installState) else { return }
        Task { [weak self] in await self?.useCase.install() }
    }

    private func confirmInstallUv() {
        guard Self.stateAllowsInstallUv(installState) else { return }
        Task { [weak self] in await self?.useCase.installUvThenPolybridge() }
    }

    private func confirmInstallAnyway() {
        guard Self.stateAllowsInstallAnyway(installState) else { return }
        Task { [weak self] in await self?.useCase.installAnyway() }
    }

    private static func stateAllowsInstall(_ state: InstallState) -> Bool {
        switch state {
        case .idle, .failed, .needsGit, .needsUv, .installed: true
        case .running, .unresolved: false
        }
    }

    private static func stateAllowsInstallUv(_ state: InstallState) -> Bool {
        if case .needsUv = state { return true }
        return false
    }

    private static func stateAllowsInstallAnyway(_ state: InstallState) -> Bool {
        if case .unresolved = state { return true }
        return false
    }
}
