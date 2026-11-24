//
//  MenuBarRuntimeCard.swift
//  MenuBarFeature
//

import HfRepository

// MARK: - MenuBarRuntimeCard

/// What the popover shows in place of its sections while the managed runtime is not ready
/// (`menu-bar/runtime-setup`, `runtime-preparing`, `runtime-failed`).
enum MenuBarRuntimeCard: Equatable, Sendable {
    case setupRequired
    case preparing
    case failed(message: String)

    /// Pure and safe off the main actor. `nil` once the runtime is ready.
    nonisolated static func card(for state: RuntimeSetupState) -> MenuBarRuntimeCard? {
        switch state {
        case .checking, .installing, .updating: .preparing
        case .installationRequired: .setupRequired
        case .failed(let message), .updateFailed(let message, _, _): .failed(message: message)
        case .ready: nil
        }
    }

    var subline: String {
        switch self {
        case .setupRequired: "Runtime setup required"
        case .preparing: "Runtime setup in progress"
        case .failed: "Runtime setup failed"
        }
    }

    var title: String? {
        switch self {
        case .setupRequired: nil
        case .preparing: "Preparing Harflow runtime…"
        case .failed: "Harflow runtime preparation failed"
        }
    }

    var text: String {
        switch self {
        case .setupRequired: "Finish setting up Harflow to see your work."
        case .preparing: "Preparing the exact paired runtime. This can take a few minutes."
        case .failed: "The managed runtime is unavailable. Try again to prepare it."
        }
    }

    var failureMessage: String? {
        if case .failed(let message) = self { message } else { nil }
    }

    var isFailed: Bool { failureMessage != nil }

    /// Setup happens in the main window, so the two states that need the person offer to open it.
    var offersOpenHarflow: Bool { self != .preparing }
}
