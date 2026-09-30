//
//  MainWindowSceneRoot.swift
//  PolybridgeMonitor
//
//  Decision 3 + 6 of the "behave like a normal Mac app" plan. Two responsibilities that have to live
//  in the app target rather than in `MainWindowFeature` (features never reach into AppKit's window
//  machinery or `@Environment(\.openWindow)` registration — see the root AGENTS.md's package graph):
//
//  - Capturing SwiftUI's `@Environment(\.openWindow)` opener and registering it through
//    `WindowPresenting`, independent of whether the menu-bar status item has ever appeared
//    (`MenuBarLabelView.onAppear` is a second, redundant route to the same registration). A URL
//    launch only `orderOut`s the window (`App.swift`'s `AppDelegate.applicationDidFinishLaunching`),
//    it never closes it, so this view's `onAppear` always fires at launch.
//  - Hosting the one-time full-screen collection-behaviour fix (`MainWindowConfigurator`) as an
//    invisible background view, since SwiftUI's `Window` scene has no direct API for
//    `NSWindow.collectionBehavior`.
//

import AppKit
import PbCommon
import SwiftUI

// MARK: - MainWindowSceneRoot

/// Wraps the main window's content (`AppCoordinator.mainWindowCoordinator.start()`) with the two
/// app-target-only concerns above.
struct MainWindowSceneRoot<Content: View>: View {

    // MARK: - Environment

    @Environment(\.openWindow) private var openWindow

    // MARK: - Properties

    let windowPresenting: any WindowPresenting
    @ViewBuilder let content: () -> Content

    // MARK: - View Body

    var body: some View {
        content()
            .background(MainWindowConfiguratorView())
            .onAppear {
                windowPresenting.registerWindowOpener { openWindow(id: "main") }
            }
    }
}

// MARK: - MainWindowConfigurator

/// The pure logic behind decision 6's full-screen fix — kept separate from the `NSViewRepresentable`
/// plumbing so it can be unit tested directly.
enum MainWindowConfigurator {
    /// Removes the collection-behavior flags that make AppKit fall back to the "zoom" full-screen
    /// behaviour (`.fullScreenAuxiliary`, `.fullScreenNone`), inserts `.fullScreenPrimary` so
    /// `⌃⌘F`/View → Enter Full Screen gives a real full-screen space, and keeps every other flag
    /// untouched.
    static func fullScreenCollectionBehavior(_ behavior: NSWindow.CollectionBehavior) -> NSWindow.CollectionBehavior {
        var result = behavior
        result.remove(.fullScreenAuxiliary)
        result.remove(.fullScreenNone)
        result.insert(.fullScreenPrimary)
        return result
    }

    /// Applies the full-screen fix and hides the title text drawn in the toolbar. The title itself
    /// stays set, so the Window menu, Mission Control and VoiceOver still name the window.
    @MainActor
    static func configure(_ window: NSWindow) {
        window.collectionBehavior = fullScreenCollectionBehavior(window.collectionBehavior)
        window.titleVisibility = .hidden
    }
}

// MARK: - MainWindowConfiguratorView

/// An invisible `NSViewRepresentable` whose sole job is to reach the hosting `NSWindow` once it
/// exists and apply `MainWindowConfigurator.configure(_:)` to it, exactly once.
struct MainWindowConfiguratorView: NSViewRepresentable {

    func makeNSView(context: Context) -> ConfiguringNSView {
        ConfiguringNSView()
    }

    func updateNSView(_ nsView: ConfiguringNSView, context: Context) {}

    /// `viewDidMoveToWindow` can fire more than once (e.g. the view is removed and re-added to the
    /// hierarchy), so `didConfigure` makes the fix idempotent rather than reapplying it every time.
    final class ConfiguringNSView: NSView {
        private var didConfigure = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didConfigure else { return }
            MainWindowConfigurator.configure(window)
            didConfigure = true
        }
    }
}
