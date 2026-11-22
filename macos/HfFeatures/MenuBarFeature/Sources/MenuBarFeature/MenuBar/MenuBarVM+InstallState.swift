//
//  MenuBarVM+InstallState.swift
//  MenuBarFeature
//

import HfRepository

// MARK: - MenuBarVM + Install state text and gates

/// Pure helpers for the install banner and its confirmation dialogs, split out of `MenuBarVM.swift`
/// to keep that file within the lint length budget.
extension MenuBarVM {

    static func runningTitle(_ stage: InstallStage) -> String {
        if case .validate = stage { return "Checking…" }
        return "Preparing Harflow runtime…"
    }

    static func runningDetail(_ stage: InstallStage) -> String {
        switch stage {
        case .git: "Checking for git…"
        case .uv: "Setting up uv…"
        case .harflow: "Preparing the exact paired runtime. This can take a few minutes."
        case .validate: "Checking the new install. This can take a little while."
        }
    }

    static func stateAllowsInstall(_ state: InstallState) -> Bool {
        switch state {
        case .idle, .failed, .needsGit, .needsUv, .installed: true
        case .running, .unresolved: false
        }
    }

    static func stateAllowsInstallUv(_ state: InstallState) -> Bool {
        if case .needsUv = state { return true }
        return false
    }

    static func stateAllowsInstallAnyway(_ state: InstallState) -> Bool {
        if case .unresolved = state { return true }
        return false
    }
}
