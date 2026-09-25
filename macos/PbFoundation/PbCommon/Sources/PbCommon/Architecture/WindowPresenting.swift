//
//  WindowPresenting.swift
//  PbCommon
//
//  A minimal seam added in Phase 4a (SettingsFeature/MenuBarFeature dispatch), ahead of the F7
//  window/navigation seam Phase 5 formalises. The menu bar's status item is the one place that
//  captures SwiftUI's `@Environment(\.openWindow)` opener (`MenuBarLabelView.onAppear`), and that
//  capture has to reach whatever ultimately owns the "show the window" action without
//  `MenuBarFeature` importing the app target — Features never import the app (see the root
//  AGENTS.md's package graph). `MenuBarCoordinator.registerWindowOpener` forwards to
//  `(parent as? WindowPresenting)?.registerWindowOpener(opener)`; the app target's root
//  `AppCoordinator` (Phase 5) conforms to this directly and stores the opener itself — there is no
//  intermediate `AppModel` or transitional coordinator any more.
//  `MonitorDestination.openWindow` remains the way a VM *asks* for the window to come forward; this
//  protocol only carries the one-time opener registration, which is not itself a navigation event.
//

import Foundation

/// Registers the closure that actually opens/brings-forward the main window. Conformed to by
/// whatever coordinator sits above a feature that needs to capture it (today, the app target's
/// `AppCoordinator`).
@MainActor
public protocol WindowPresenting: AnyObject {
    /// Registers the window-opening closure. Called at most meaningfully once per process (the
    /// status item never disappears), but safe to call again — a later registration simply
    /// replaces the earlier one.
    func registerWindowOpener(_ opener: @escaping () -> Void)
}
