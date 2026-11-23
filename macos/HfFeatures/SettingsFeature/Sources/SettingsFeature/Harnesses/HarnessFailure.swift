//
//  HarnessFailure.swift
//  SettingsFeature
//

import MonitorCore

// MARK: - HarnessLoadFailure

/// A failed status load as the Harnesses page shows it: the engine's sentence, and the refusal code on a
/// detail line instead of inside the sentence.
struct HarnessLoadFailure: Equatable, Sendable {
    let message: String
    let code: String?
}

// MARK: - HarnessRowFailure

/// A failed install, update or removal, shown on the row it acted on with a Retry that repeats the same action.
struct HarnessRowFailure: Equatable, Sendable {
    let message: String
    let code: String?
    let action: SetupClient.Action
}
