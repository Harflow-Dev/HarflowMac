//
//  AppDelegateVisibilityTests.swift
//  PolybridgeMonitorTests
//
//  B1: the app shell feeds `MonitorVisibility` from the main window's occlusion/miniaturize/close
//  state, through injectable seams — no real notification center, no real window server event.
//

import AppKit
import Foundation
@testable import PolybridgeMonitor
import Testing

/// A window whose occlusion and miniaturized state a test sets directly.
@MainActor
private final class StateWindow: NSWindow {
    var fakeOcclusion: NSWindow.OcclusionState = []
    var fakeMiniaturized = false
    override var occlusionState: NSWindow.OcclusionState { fakeOcclusion }
    override var isMiniaturized: Bool { fakeMiniaturized }
}

@MainActor
@Suite struct AppDelegateVisibilityTests {

    private func makeWindow(visible: Bool, miniaturized: Bool = false) -> StateWindow {
        let window = StateWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        window.fakeOcclusion = visible ? [.visible] : []
        window.fakeMiniaturized = miniaturized
        return window
    }

    private func makeSUT(windows: @escaping @MainActor () -> [NSWindow]) -> (sut: AppDelegate, updates: LockedBox<[Bool]>) {
        let sut = AppDelegate()
        let updates = LockedBox<[Bool]>([])
        sut.mainWindows = windows
        sut.updateMainWindowVisibility = { visible in updates.value.append(visible) }
        return (sut, updates)
    }

    @Test(arguments: [(true, false, true), (false, false, false), (true, true, false)])
    func givenAWindowState_whenVisibilityIsComputed_thenItNeedsOcclusionVisibleAndNotMiniaturized(
        occlusionVisible: Bool, miniaturized: Bool, expected: Bool
    ) {
        // given
        let window = makeWindow(visible: occlusionVisible, miniaturized: miniaturized)
        let (sut, updates) = makeSUT { [window] }

        // when
        sut.updateMainWindowVisibilityFromWindows()

        // then
        #expect(updates.value == [expected])
    }

    @Test func givenNoMainWindow_whenVisibilityIsComputed_thenItIsHidden() {
        // given
        let (sut, updates) = makeSUT { [] }

        // when
        sut.updateMainWindowVisibilityFromWindows()

        // then
        #expect(updates.value == [false])
    }

    @Test func givenTheClosingWindowIsStillVisible_whenItIsExcluded_thenVisibilityIsFalse() {
        // given — `willClose` fires while the window still reports itself visible.
        let window = makeWindow(visible: true)
        let (sut, updates) = makeSUT { [window] }

        // when
        sut.updateMainWindowVisibilityFromWindows(excluding: window)

        // then
        #expect(updates.value == [false])
    }

    @Test func givenStartedObserving_whenEachNotificationFires_thenVisibilityIsRecomputedFromTheWindows() {
        // given
        let window = makeWindow(visible: true)
        let handlers = LockedBox<[Notification.Name: @MainActor (Notification) -> Void]>([:])
        let (sut, updates) = makeSUT { [window] }
        sut.addWindowVisibilityObserver = { name, handler in
            handlers.value[name] = handler
            return NSObject()
        }

        // when
        sut.startObservingWindowVisibility()
        sut.startObservingWindowVisibility()

        // then — one observer per notification, registered once.
        #expect(Set(handlers.value.keys) == [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification
        ])

        // when — the window is covered, then miniaturized-and-back, then closed.
        window.fakeOcclusion = []
        handlers.value[NSWindow.didChangeOcclusionStateNotification]?(Notification(name: NSWindow.didChangeOcclusionStateNotification, object: window))
        window.fakeOcclusion = [.visible]
        handlers.value[NSWindow.didDeminiaturizeNotification]?(Notification(name: NSWindow.didDeminiaturizeNotification, object: window))
        handlers.value[NSWindow.willCloseNotification]?(Notification(name: NSWindow.willCloseNotification, object: window))

        // then
        #expect(updates.value == [false, true, false])
    }
}
