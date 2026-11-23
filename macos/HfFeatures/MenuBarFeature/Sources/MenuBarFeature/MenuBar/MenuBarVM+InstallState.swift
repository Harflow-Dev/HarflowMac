//
//  MenuBarVM+InstallState.swift
//  MenuBarFeature
//

import HfRepository

// MARK: - MenuBarVM + Install state text

/// Pure helpers for the install banner, split out of `MenuBarVM.swift`
/// to keep that file within the lint length budget.
extension MenuBarVM {

    static func runningTitle(_ stage: InstallStage) -> String {
        if case .validate = stage { return "Checking…" }
        return "Preparing Harflow runtime…"
    }

    static func runningDetail(_ stage: InstallStage) -> String {
        switch stage {
        case .harflow: "Preparing the exact paired runtime. This can take a few minutes."
        case .validate: "Checking the new install. This can take a little while."
        }
    }
}
