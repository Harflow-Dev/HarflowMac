//
//  AppCoordinator.swift
//  PolybridgeMonitor
//
//  The real root coordinator (settled plan's "Window and navigation seam" + review finding F7),
//  replacing `TransitionalAppCoordinator`. Its three children — `MainWindowCoordinator`,
//  `MenuBarCoordinator`, `SettingsCoordinator` — come from the `GlobalValues` feature factories,
//  exactly as `TransitionalAppCoordinator` built them, but this type owns navigation state directly
//  (`GlobalValues.taskListRepository`/`settingsRepository`) instead of going through an `AppModel`
//  façade, which no longer exists.
//
//  `handle(path:)` for `MonitorDestination`: `.task`/`.group`/`.newSession` delegate to
//  `MainWindowCoordinator` (which owns `selection`/`isNewSessionPresented`); `.openWindow` goes
//  through `WindowPresenting` — `NSApp.activate(ignoringOtherApps:)`, then the opener captured in
//  `MenuBarLabelView.onAppear` via `MenuBarCoordinator.registerWindowOpener`. The directory-chooser
//  panel already lives in `MainWindowCoordinator` (`NewSessionRouting.chooseDirectory`) — nothing
//  else is needed here for it.
//
//  URL handling (`polybridge-monitor://task/<id>`, F4-23/F4-25, revised for piece 10 — "a task
//  starting doesn't close/reopen an open window"): an invalid URL is ignored. A valid one, when the
//  main window is already visible (`isMainWindowVisible`, the same identifier-prefix/visible/not-
//  miniaturized rule `AppDelegate.applicationShouldHandleReopen`'s `mainWindows()` seam uses, plus
//  `NSApp.isHidden` so a ⌘H-hidden app counts as not visible), only fires a fire-and-forget
//  `TaskListRepository.refresh()` — no selection change, no sidebar reveal, no activation, no window
//  re-order. The URLs that launched the app go through `handleLaunchURL(_:)` instead, which always
//  selects (the window then is SwiftUI's own initial one). Doing any of those to a window the user already has open and arranged is what made it
//  "close and pop back" on every task start (Nayanda's report). Only when the window is *not*
//  visible does it fall back to the previous behaviour: select the task via `handle(path:)` (which
//  also requests the sidebar reveal), refresh, and bring the window forward only when
//  `SettingsRepository.openWindowOnStart` is on. Notification-click handling (`AppDelegate`) is
//  unaffected either way — it instead calls `handle(path:)` for `.task` then `.openWindow` directly,
//  which brings the window forward unconditionally (F4-32), regardless of visibility.
//
//  `mainWindowCoordinator`/`menuBarCoordinator`/`settingsCoordinator` are `lazy var`s, exactly as
//  `TransitionalAppCoordinator`'s were: `PolybridgeMonitorApp.init()` still creates `AppCoordinator`
//  itself synchronously (this file's whole point), and a URL/notification arriving before any
//  `Scene` body has ever rendered still works, because Swift resolves a `lazy var` on its very first
//  access, from wherever that access comes.
//

import AppKit
import Foundation
import MainWindowFeature
import MenuBarFeature
import MonitorCore
import PbCommon
import PbRepository
import PbUtilities
import SwiftEnvironment

// MARK: - WindowSnapshot

/// A window's identifier/visibility/miniaturized state, decoupled from `NSWindow` so
/// `isMainWindowVisible(_:appHidden:)` below is a pure function testable with plain values instead
/// of a real window — mirroring why `AppDelegateTests`' `VisibilityFakeWindow` exists at all:
/// `isVisible`/`isMiniaturized` are not reliably drivable on a real, never-ordered-front `NSWindow`
/// in a headless test run.
struct WindowSnapshot {
    let identifier: String?
    let isVisible: Bool
    let isMiniaturized: Bool
}

/// Same rule `AppDelegate.applicationShouldHandleReopen` uses over its own `mainWindows()` seam
/// (`App.swift`): a main window (identifier prefix "main") that is on screen and not miniaturized.
/// `appHidden` is checked separately rather than folded into a window's own state — AppKit does not
/// flip `isVisible` when the app is hidden with ⌘H, so a hidden app's window would otherwise still
/// read as visible here.
func isMainWindowVisible(_ windows: [WindowSnapshot], appHidden: Bool) -> Bool {
    !appHidden && windows.contains { $0.identifier?.hasPrefix("main") == true && $0.isVisible && !$0.isMiniaturized }
}

// MARK: - LaunchURLHandling

/// The URLs that launched the app. The window on screen then is the one SwiftUI opened by itself —
/// `AppDelegate` may still order it out — so its task is always selected, whatever
/// `isMainWindowVisible` says. `AppDelegate` alone decides which batch that is, from its own launch
/// clock, so there is exactly one anchor for "launch".
@MainActor
public protocol LaunchURLHandling: AnyObject {
    @discardableResult func handleLaunchURL(_ url: URL) -> Bool
}

// MARK: - AppCoordinator

/// The application's root coordinator. Has no parent; every other coordinator in the app eventually
/// bubbles an unhandled `handle(path:)` call up to this one.
@MainActor
public final class AppCoordinator: ParentCoordinator, WindowPresenting, LaunchURLHandling {
    
    // MARK: - Coordinator
    
    public var path: [PathDestination] { [] }
    
    /// macOS has no single mutually-exclusive "active shell" the way an iOS root coordinator's
    /// splash/onboarding/main destinations do — the window, the menu bar and Settings are all live
    /// scenes at once, so there is no one meaningful `activeChild` to report.
    public var activeChild: ChildCoordinator? { nil }
    
    // MARK: - Private properties
    
    private let mainWindowFeatureFactoryValue: any MainWindowFeatureFactory
    private let menuBarFeatureFactoryValue: any MenuBarFeatureFactory
    private let settingsFeatureFactoryValue: any SettingsFeatureFactory
    private let taskListRepositoryValue: any TaskListRepository
    private let settingsRepositoryValue: any SettingsRepository
    private let activateApp: () -> Void
    private let isMainWindowVisible: () -> Bool
    private var openWindowOpener: (() -> Void)?
    
    // MARK: - Init
    
    /// - Parameters:
    ///   - mainWindowFeatureFactory: Overridable for tests; defaults to the registered
    ///     `GlobalValues.mainWindowFeatureFactory` (the init-override test-injection pattern used
    ///     throughout this app's coordinators and view repositories).
    ///   - activateApp: Overridable for tests, so `showWindow()`'s ordering (F4-24) can be observed
    ///     without a real `NSApp.activate(ignoringOtherApps:)` call.
    ///   - isMainWindowVisible: Overridable for tests, so `handle(url:)`'s in-place-vs-reopen branch
    ///     (piece 10) can be driven without real `NSWindow`s. Defaults to
    ///     `isMainWindowVisible(_:appHidden:)` over `NSApp.windows`/`NSApp.isHidden`.
    public init(
        mainWindowFeatureFactory: (any MainWindowFeatureFactory)? = nil,
        menuBarFeatureFactory: (any MenuBarFeatureFactory)? = nil,
        settingsFeatureFactory: (any SettingsFeatureFactory)? = nil,
        taskListRepository: (any TaskListRepository)? = nil,
        settingsRepository: (any SettingsRepository)? = nil,
        activateApp: (() -> Void)? = nil,
        isMainWindowVisible: (() -> Bool)? = nil
    ) {
        self.mainWindowFeatureFactoryValue = mainWindowFeatureFactory ?? GlobalValues.mainWindowFeatureFactory
        self.menuBarFeatureFactoryValue = menuBarFeatureFactory ?? GlobalValues.menuBarFeatureFactory
        self.settingsFeatureFactoryValue = settingsFeatureFactory ?? GlobalValues.settingsFeatureFactory
        self.taskListRepositoryValue = taskListRepository ?? GlobalValues.taskListRepository
        self.settingsRepositoryValue = settingsRepository ?? GlobalValues.settingsRepository
        self.activateApp = activateApp ?? { NSApp.activate(ignoringOtherApps: true) }
        self.isMainWindowVisible = isMainWindowVisible ?? {
            PolybridgeMonitor.isMainWindowVisible(
                NSApp.windows.map {
                    WindowSnapshot(identifier: $0.identifier?.rawValue, isVisible: $0.isVisible, isMiniaturized: $0.isMiniaturized)
                },
                appHidden: NSApp.isHidden
            )
        }
    }
    
    // MARK: - ParentCoordinator
    
    public func childDidStop(_ child: ChildCoordinator) {}
    
    // MARK: - Coordinator
    
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard let id = MonitorURL.taskID(from: url) else { return false }
        guard !isMainWindowVisible() else {
            // The window is already on screen: only refresh the list so the new task appears in
            // it. Selecting it, revealing it in the sidebar, activating the app, or re-opening the
            // window would disturb a window the user already has arranged — exactly what made it
            // "close and pop back" on every task start.
            Task { await taskListRepositoryValue.refresh() }
            return true
        }
        openTask(id)
        return true
    }
    
    public func handle(path: any PathDestination) {
        guard let destination = path as? MonitorDestination else { return }
        switch destination {
        case .task, .group, .workflow, .newWorkflow, .workflowRun:
            mainWindowCoordinator.handle(path: destination)
        case .newSession:
            // Decision 5: ⌘N (or the File menu item) must bring the window forward before the New
            // Session sheet is presented — `MainWindowCoordinator` only flips a `Bool` flag, which
            // does nothing while the window is closed.
            showWindow()
            mainWindowCoordinator.handle(path: destination)
        case .openWindow:
            showWindow()
        }
    }
    
    // MARK: - LaunchURLHandling

    @discardableResult
    public func handleLaunchURL(_ url: URL) -> Bool {
        guard let id = MonitorURL.taskID(from: url) else { return false }
        openTask(id)
        return true
    }

    // MARK: - WindowPresenting
    
    public func registerWindowOpener(_ opener: @escaping () -> Void) {
        openWindowOpener = opener
    }
    
    // MARK: - Feature coordinators
    
    lazy var mainWindowCoordinator: any ViewChildCoordinator = mainWindowFeatureFactoryValue.makeMainWindowCoordinator(asChildOf: self)
    lazy var menuBarCoordinator: any ViewChildCoordinator = menuBarFeatureFactoryValue.makeMenuBarCoordinator(asChildOf: self)
    lazy var settingsCoordinator: any ViewChildCoordinator = settingsFeatureFactoryValue.makeSettingsCoordinator(asChildOf: self)
    
    /// Typed access to the main window's navigation state and view builders — `ViewChildCoordinator`
    /// alone only exposes `start()`.
    var mainWindowNavigationCoordinator: (any MainWindowNavigationCoordinator)? { mainWindowCoordinator as? MainWindowNavigationCoordinator }
    
    /// Typed access to the menu bar's two independent view builders (`MenuBarExtra` takes its label
    /// and content as two separate view builders).
    var menuBarNavigationCoordinator: (any MenuBarNavigationCoordinator)? { menuBarCoordinator as? MenuBarNavigationCoordinator }
    
    // MARK: - Private methods

    private func openTask(_ id: String) {
        // Through `handle(path:)`, not a direct `selection` write: that path also requests the
        // sidebar reveal, so a task opened by URL is never left hidden inside a collapsed parent.
        mainWindowCoordinator.handle(path: MonitorDestination.task(id))
        Task { await taskListRepositoryValue.refresh() }
        if settingsRepositoryValue.openWindowOnStart { showWindow() }
    }
    
    /// F4-24: `NSApp.activate` runs before the captured opener, every time.
    private func showWindow() {
        activateApp()
        openWindowOpener?()
    }
}
