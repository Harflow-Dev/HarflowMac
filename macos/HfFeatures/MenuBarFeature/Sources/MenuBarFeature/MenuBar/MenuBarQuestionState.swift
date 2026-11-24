//
//  MenuBarQuestionState.swift
//  MenuBarFeature
//

import Foundation

// MARK: - MenuBarQuestionState

/// The inline answer card of a plain question row (`menu-bar/question-*`): the draft and what the card is doing with it.
struct MenuBarQuestionState: Equatable, Sendable {
    enum Action: Equatable, Sendable {
        case none
        /// The card offers Open, which routes to the Needs you item.
        case open
    }

    enum Phase: Equatable, Sendable {
        case editing
        case submitting
        case failed(message: String, code: String?)
        /// Delivery could not be confirmed. The answer is never sent again.
        case unknown
        case settled(title: String?, lines: [String], action: Action)
    }

    static let submittingStatus = "Submitting your answer to the Harflow runtime…"
    static let unknownStatus = "Harflow couldn't confirm your answer was received. Open Needs you to check."

    var draft: String
    var phase: Phase

    init(draft: String = "", phase: Phase = .editing) {
        self.draft = draft
        self.phase = phase
    }

    /// What VoiceOver reads when the card moves on: the status, the failure, or the settled result. Nothing while editing.
    var announcement: String? {
        switch phase {
        case .editing: nil
        case .submitting: Self.submittingStatus
        case .unknown: Self.unknownStatus
        case .failed(let message, _): message
        case .settled(let title, let lines, _): ([title].compactMap(\.self) + lines).joined(separator: ". ")
        }
    }

    /// Whether the field takes input: only before an answer is in flight or settled.
    var fieldEnabled: Bool {
        switch phase {
        case .editing, .failed: true
        case .submitting, .unknown, .settled: false
        }
    }

    var canSubmit: Bool { fieldEnabled && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Settled and unknown cards are held until the popover closes.
    var isHeld: Bool {
        switch phase {
        case .settled, .unknown: true
        case .editing, .submitting, .failed: false
        }
    }
}
