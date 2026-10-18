//
//  AlertContent.swift
//  PbCommon
//
//  Sized against the Monitor's
//  four existing `confirmationDialog`s (TaskDetailView.swift:84-97, ParallelView.swift:55-58,123-131,
//  SettingsView.swift:102-109), none of which need more than a title, an optional message, and a
//  small list of buttons — some destructive, one occasionally `.cancel`.
//

import Dummyable
import Foundation
import PbUtilities
import SwiftUI

// MARK: - AlertContent

/// A title, an optional message, and the buttons to present for an alert or confirmation dialog.
@Dummyable
public struct AlertContent: Hashable, Sendable {
    // periphery:ignore - Maintains Hashable synthesized conformance consistency.
    let id: UUID = .init()
    public let title: String
    public let description: String?
    public let actions: [AlertAction]
    
    public init(title: String, description: String? = nil, @ArrayBuilder<AlertAction> actionsBuilder: () -> [AlertAction]) {
        self.title = title
        self.description = description
        self.actions = actionsBuilder()
    }
}

// MARK: - AlertAction

/// One button in an ``AlertContent``, with an optional `ButtonRole` (e.g. `.destructive`, `.cancel`).
@Dummyable
public struct AlertAction: Sendable {
    let id: UUID = .init()
    public let title: String
    public let role: ButtonRole?
    public let action: @MainActor () -> Void
    
    @DummyableInit
    public init(title: String, role: ButtonRole? = nil, action: @MainActor @escaping () -> Void = {}) {
        self.title = title
        self.role = role
        self.action = action
    }
}

extension AlertAction: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(title)
    }
    
    public static func == (lhs: AlertAction, rhs: AlertAction) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.role == rhs.role
    }
}
