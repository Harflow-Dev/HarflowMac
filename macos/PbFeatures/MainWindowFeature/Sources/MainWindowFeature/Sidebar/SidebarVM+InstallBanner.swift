//
//  SidebarVM+InstallBanner.swift
//  MainWindowFeature
//
//  Split out of SidebarVM.swift purely to keep that file under the swiftlint length budget —
//  same VM, same behaviour.
//

import Foundation
import PbCommon
import PbRepository
import PbUI

// MARK: - SidebarVM + Install banner (settled plan, section 5)

/// Maps `InstallState`/`InstallNeed` to `InstallBanner.Model` and the three confirmation dialogs.
/// PbUI can't see `InstallState` (Core doesn't depend on UI), so this mapping lives here — a small,
/// per-feature helper duplicated in `MenuBarVM`/`HarnessesVM`, not shared, per the settled plan.
extension SidebarVM {

    /// Split out of `subscribeIfNeeded()` to keep that function within the lint length budget.
    /// `private` is file-scoped in Swift, and `subscribeIfNeeded()` lives in `SidebarVM.swift` —
    /// hence no access modifier (internal), not `private`, on this and the other cross-file members
    /// below.
    func subscribeToInstallState() {
        useCase.installStatePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                installState = state
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

        useCase.installAnywayBlockedMessagePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                installAnywayBlockedMessage = message
                recomputeInstallBanner()
            }
            .store(in: &cancellables)
    }

    func recomputeInstallBanner() {
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
            if let need = currentInstallNeed, let error = latestListError {
                installBannerModel = InstallBanner.Model(
                    title: need == .missing ? "polybridge isn't installed" : "polybridge is incomplete or out of date",
                    detail: error.message,
                    primaryTitle: need == .missing ? "Install polybridge" : "Update polybridge"
                )
            } else if latestListError != nil {
                // A current tool error that isn't an install need still outranks the success
                // banner (R2-2) — the plain red `listErrorMessage` shows instead, banner-free.
                installBannerModel = nil
            } else if installState == .installed {
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
        // The empty-state message's own precedence gates on `installBannerModel == nil` (Review
        // round 1 item 3), so a banner appearing or clearing must recompute it too — otherwise
        // dismissing a success banner over an empty list left the empty-state text missing until
        // some unrelated event (a new listing, a search keystroke) happened to recompute it (Code
        // review round 1, finding 4).
        emptyStateMessage = computeEmptyStateMessage()
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

    func publishInstallOrUpdateDialog(need: InstallNeed) {
        let isMissing = need == .missing
        let message = "This replaces the polybridge installation used by agent sessions. Existing sessions may be disrupted "
            + "or fail on later operations. Finish running tasks and close sessions using polybridge before continuing. "
            + "polybridge will be installed from GitHub with uv." + destinationLine()
        publishDialog(isMissing ? "Install polybridge?" : "Update polybridge?", description: message) {
            AlertAction(title: isMissing ? "Install" : "Update") { [weak self] in self?.confirmInstallOrUpdate() }
        }
    }

    func publishInstallUvDialog() {
        publishDialog(
            "Install uv?",
            description: "uv is needed to install polybridge. Install it now with astral's official installer? "
                + "This downloads and runs https://astral.sh/uv/install.sh, then installs polybridge."
        ) {
            AlertAction(title: "Install uv") { [weak self] in self?.confirmInstallUv() }
        }
    }

    func publishInstallAnywayDialog() {
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
