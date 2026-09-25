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
//  `handle(path:)` for `MonitorDestination`: `.task`/`.group`/`.interactive`/`.newSession` delegate
//  to `MainWindowCoordinator` (which owns `selection`/`isNewSessionPresented`); `.openWindow` goes
//  through `WindowPresenting` — `NSApp.activate(ignoringOtherApps:)`, then the opener captured in
//  `MenuBarLabelView.onAppear` via `MenuBarCoordinator.registerWindowOpener`. The directory-chooser
//  panel already lives in `MainWindowCoordinator` (`NewSessionRouting.chooseDirectory`) — nothing
//  else is needed here for it.
//
//  URL handling (`polybridge-monitor://task/<id>`, F4-23/F4-25): an invalid URL is ignored; a valid
//  one selects the task, fires a fire-and-forget `TaskListRepository.refresh()`, and brings the
//  window forward only when `SettingsRepository.openWindowOnStart` is on. Notification-click
//  handling (`AppDelegate`) instead calls `handle(path:)` for `.task` then `.openWindow` directly,
//  which brings the window forward unconditionally (F4-32) — the difference between the two paths is
//  exactly the settled plan's "the toggle applies to URL launches, never to a notification click."
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

// MARK: - AppCoordinator

/// The application's root coordinator. Has no parent; every other coordinator in the app eventually
/// bubbles an unhandled `handle(path:)` call up to this one.
@MainActor
public final class AppCoordinator: ParentCoordinator, WindowPresenting {
    
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
    private var openWindowOpener: (() -> Void)?
    
    // MARK: - Init
    
    /// - Parameters:
    ///   - mainWindowFeatureFactory: Overridable for tests; defaults to the registered
    ///     `GlobalValues.mainWindowFeatureFactory` (the init-override test-injection pattern used
    ///     throughout this app's coordinators and view repositories).
    ///   - activateApp: Overridable for tests, so `showWindow()`'s ordering (F4-24) can be observed
    ///     without a real `NSApp.activate(ignoringOtherApps:)` call.
    public init(
        mainWindowFeatureFactory: (any MainWindowFeatureFactory)? = nil,
        menuBarFeatureFactory: (any MenuBarFeatureFactory)? = nil,
        settingsFeatureFactory: (any SettingsFeatureFactory)? = nil,
        taskListRepository: (any TaskListRepository)? = nil,
        settingsRepository: (any SettingsRepository)? = nil,
        activateApp: (() -> Void)? = nil
    ) {
        self.mainWindowFeatureFactoryValue = mainWindowFeatureFactory ?? GlobalValues.mainWindowFeatureFactory
        self.menuBarFeatureFactoryValue = menuBarFeatureFactory ?? GlobalValues.menuBarFeatureFactory
        self.settingsFeatureFactoryValue = settingsFeatureFactory ?? GlobalValues.settingsFeatureFactory
        self.taskListRepositoryValue = taskListRepository ?? GlobalValues.taskListRepository
        self.settingsRepositoryValue = settingsRepository ?? GlobalValues.settingsRepository
        self.activateApp = activateApp ?? { NSApp.activate(ignoringOtherApps: true) }
    }
    
    // MARK: - ParentCoordinator
    
    public func childDidStop(_ child: ChildCoordinator) {}
    
    // MARK: - Coordinator
    
    @discardableResult
    public func handle(url: URL) -> Bool {
        guard let id = MonitorURL.taskID(from: url) else { return false }
        mainWindowNavigationCoordinator?.selection = .task(id)
        Task { await taskListRepositoryValue.refresh() }
        if settingsRepositoryValue.openWindowOnStart { showWindow() }
        return true
    }
    
    public func handle(path: any PathDestination) {
        guard let destination = path as? MonitorDestination else { return }
        switch destination {
        case .task, .group, .interactive, .newSession:
            mainWindowCoordinator.handle(path: destination)
        case .openWindow:
            showWindow()
        }
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
    
    /// F4-24: `NSApp.activate` runs before the captured opener, every time.
    private func showWindow() {
        activateApp()
        openWindowOpener?()
    }
}
