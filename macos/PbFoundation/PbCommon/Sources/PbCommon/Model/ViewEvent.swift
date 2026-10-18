//
//  ViewEvent.swift
//  PbCommon
//
//  Only the case names the Monitor actually
//  uses (decision 10): `alert`, `dialog`, `none`. There is no `toast` case — the Monitor has none
//  today, and the outcome line stays durable VM state (decision 4), not a transient view event.
//

import Foundation
import SwiftUI

/// A one-shot presentation command a view model sends to its view.
public enum ViewEvent: Hashable, Sendable {
    case alert(AlertContent)
    case dialog(AlertContent)
    /// Actionable read failure; its source identifies independent recovery.
    case incident(source: String, message: String, retry: AlertAction? = nil)
    /// A successful authoritative read clears only this source.
    case incidentResolved(source: String)
    case none
    
    /// The payload when this event is `.alert`.
    public var alert: AlertContent? {
        guard case .alert(let alert) = self else { return nil }
        return alert
    }
    
    /// The payload when this event is `.dialog`.
    public var dialog: AlertContent? {
        guard case .dialog(let dialog) = self else { return nil }
        return dialog
    }
}

public extension EnvironmentValues {
    /// The binding a view reads to observe the view model's latest ``ViewEvent``, and the
    /// presentation modifier (PbUI) writes to reset it back to `.none` after presenting.
    @Entry var viewEvent: Binding<ViewEvent> = .constant(.none)
}
