//
//  WindowSnapshotTests.swift
//  PolybridgeMonitorTests
//
//  Piece 10 ("a task starting doesn't close/reopen an open window"): `isMainWindowVisible(_:appHidden:)`
//  is a pure function over `WindowSnapshot` values, so these tests need no real `NSWindow` at all —
//  unlike `AppDelegateTests`' `VisibilityFakeWindow`, which exists only because the *other* consumer of
//  this same rule (`AppDelegate.applicationShouldHandleReopen`) is driven from real `NSWindow`s.
//

@testable import PolybridgeMonitor
import Testing

@Suite struct WindowSnapshotTests {

    @Test func givenNoWindows_whenChecked_thenNothingIsVisible() {
        // given / when
        let result = isMainWindowVisible([], appHidden: false)

        // then
        #expect(!result)
    }

    @Test func givenOnlyNonMainWindows_whenChecked_thenNothingIsVisible() {
        // given — a Settings window and a menu-bar popover (nil identifier), both visible.
        let windows = [
            WindowSnapshot(identifier: "com_apple_SwiftUI_Settings_window", isVisible: true, isMiniaturized: false),
            WindowSnapshot(identifier: nil, isVisible: true, isMiniaturized: false)
        ]

        // when
        let result = isMainWindowVisible(windows, appHidden: false)

        // then
        #expect(!result)
    }

    @Test func givenAVisibleMainWindow_whenChecked_thenItIsVisible() {
        // given
        let windows = [WindowSnapshot(identifier: "main", isVisible: true, isMiniaturized: false)]

        // when
        let result = isMainWindowVisible(windows, appHidden: false)

        // then
        #expect(result)
    }

    @Test func givenAMiniaturizedMainWindow_whenChecked_thenItIsNotVisible() {
        // given
        let windows = [WindowSnapshot(identifier: "main", isVisible: true, isMiniaturized: true)]

        // when
        let result = isMainWindowVisible(windows, appHidden: false)

        // then
        #expect(!result)
    }

    @Test func givenAnOrderedOutMainWindow_whenChecked_thenItIsNotVisible() {
        // given — `isVisible == false` (ordered out), not miniaturized.
        let windows = [WindowSnapshot(identifier: "main", isVisible: false, isMiniaturized: false)]

        // when
        let result = isMainWindowVisible(windows, appHidden: false)

        // then
        #expect(!result)
    }

    @Test func givenSeveralWindowsWithOneVisibleMain_whenChecked_thenItIsVisible() {
        // given
        let windows = [
            WindowSnapshot(identifier: nil, isVisible: true, isMiniaturized: false),
            WindowSnapshot(identifier: "com_apple_SwiftUI_Settings_window", isVisible: true, isMiniaturized: false),
            WindowSnapshot(identifier: "main", isVisible: true, isMiniaturized: false)
        ]

        // when
        let result = isMainWindowVisible(windows, appHidden: false)

        // then
        #expect(result)
    }

    @Test func givenAVisibleMainWindow_whenTheAppIsHidden_thenItIsNotVisible() {
        // given — ⌘H: AppKit does not flip `isVisible` on the window itself, so `appHidden` must be
        // checked independently.
        let windows = [WindowSnapshot(identifier: "main", isVisible: true, isMiniaturized: false)]

        // when
        let result = isMainWindowVisible(windows, appHidden: true)

        // then
        #expect(!result)
    }
}
