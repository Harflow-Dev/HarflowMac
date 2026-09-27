//
//  AppDelegateTests.swift
//  PolybridgeMonitorTests
//
//  MS-APP-1 (2 s URL-launch window / 0.8 s window-hiding timer), MS-APP-2 (last window closing),
//  MS-APP-3 (notification click), F4-29 (notification delegate only for a `.app` bundle), and the
//  app shell's own thin slice of MS-LIST-1/F4-01 (call `TaskListRepository.start()` once at launch —
//  the discovery→list→watch *ordering* itself is `TaskListRepositoryImpl`'s own, already-tested
//  contract). Every timer/clock/AppKit touch point is driven through `AppDelegate`'s injected seams,
//  never a real sleep or a real notification center.
//

import AppKit
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbCommonTestMock
@testable import PolybridgeMonitor
import Testing
@preconcurrency import UserNotifications

@MainActor
@Suite struct AppDelegateTests {
    
    // MARK: - Helpers
    
    /// Captures the closure `applicationDidFinishLaunching` hands to `scheduleAfter` instead of
    /// letting a real 0.8 s timer run, so a test can fire it deterministically.
    private func makeSUT() -> (
        sut: AppDelegate, firedScheduled: LockedBox<[(delay: TimeInterval, action: @MainActor () -> Void)]>,
        orderedOutWindows: LockedBox<[NSWindow]>, nowBox: LockedBox<Date>
    ) {
        let sut = AppDelegate()
        let firedScheduled = LockedBox<[(delay: TimeInterval, action: @MainActor () -> Void)]>([])
        let orderedOutWindows = LockedBox<[NSWindow]>([])
        let nowBox = LockedBox(Date())
        
        sut.now = { nowBox.value }
        // Captures the *requested delay* too (Codex review round 1's finding): a fake that only
        // captured the closure and discarded `delay` would stay green even if production scheduling
        // changed to 0 s or 8 s — see `givenAppLaunch_whenStarting_thenTheWindowHidingTimerIsScheduledForPointEightSeconds`.
        sut.scheduleAfter = { delay, action in firedScheduled.value.append((delay, action)) }
        sut.isRunningAsApp = { true }
        sut.mainWindows = { [] }
        sut.orderOutWindow = { orderedOutWindows.value.append($0) }
        sut.setNotificationDelegate = { _ in }
        sut.startTaskListing = {}
        sut.startBackendsCatalog = {}
        sut.notifyBackendsAppActive = {}
        sut.openWindowOnStart = { true }
        
        return (sut, firedScheduled, orderedOutWindows, nowBox)
    }
    
    // MARK: - MS-APP-1: 2 s URL-launch window, 0.8 s window-hiding timer
    
    @Test func givenAppLaunch_whenStarting_thenTheWindowHidingTimerIsScheduledForPointEightSeconds() {
        // given
        let (sut, scheduled, _, _) = makeSUT()
        
        // when
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        
        // then — the exact delay, not just that *some* delay was scheduled (Codex review round 1: a
        // fake that discarded `delay` would stay green even if production changed it to 0 s or 8 s).
        #expect(scheduled.value.map(\.delay) == [0.8])
    }
    
    @Test func givenAURLWithinTwoSeconds_whenLaunchTimerFires_thenItCountsAsAURLLaunch() {
        // given
        let (sut, scheduled, orderedOut, nowBox) = makeSUT()
        sut.openWindowOnStart = { false }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        sut.mainWindows = { [window] }
        let launchTime = nowBox.value
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        #expect(scheduled.value.count == 1)
        
        // when — a URL arrives 1 s after launch (within the 2 s window)
        nowBox.value = launchTime.addingTimeInterval(1)
        sut.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/abc123")!])
        scheduled.value.first?.action()
        
        // then — counted as a URL launch, toggle off, so the window is ordered out
        #expect(orderedOut.value.count == 1)
        #expect(orderedOut.value.first === window)
    }
    
    @Test func givenAURLLaunchAndTheToggleOff_whenTheLaunchTimerFires_thenTheWindowIsOrderedOut() {
        // given
        let (sut, scheduled, orderedOut, nowBox) = makeSUT()
        sut.openWindowOnStart = { false }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        sut.mainWindows = { [window] }
        let launchTime = nowBox.value
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        nowBox.value = launchTime.addingTimeInterval(0.5)
        sut.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/abc123")!])
        
        // when
        scheduled.value.first?.action()
        
        // then
        #expect(orderedOut.value == [window])
    }
    
    @Test func givenAURLLaunchAndTheToggleOn_whenTheLaunchTimerFires_thenTheWindowStays() {
        // given
        let (sut, scheduled, orderedOut, nowBox) = makeSUT()
        sut.openWindowOnStart = { true }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        sut.mainWindows = { [window] }
        let launchTime = nowBox.value
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        nowBox.value = launchTime.addingTimeInterval(0.5)
        sut.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/abc123")!])
        
        // when
        scheduled.value.first?.action()
        
        // then — the toggle being on always keeps the window, even after a URL launch.
        #expect(orderedOut.value.isEmpty)
    }
    
    @Test func givenAManualLaunch_whenTheLaunchTimerFires_thenTheWindowStays() {
        // given — no `application(_:open:)` call at all: a plain double-click launch.
        let (sut, scheduled, orderedOut, _) = makeSUT()
        sut.openWindowOnStart = { false }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        sut.mainWindows = { [window] }
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        
        // when
        scheduled.value.first?.action()
        
        // then — `launchedByURL` stays false regardless of the toggle, so the window is kept.
        #expect(orderedOut.value.isEmpty)
    }
    
    @Test func givenAURLArrivingAfterTwoSeconds_whenTheLaunchTimerFires_thenTheWindowStays() {
        // given
        let (sut, scheduled, orderedOut, nowBox) = makeSUT()
        sut.openWindowOnStart = { false }
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        sut.mainWindows = { [window] }
        let launchTime = nowBox.value
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        
        // when — the URL arrives 3 s after launch, outside the 2 s window.
        nowBox.value = launchTime.addingTimeInterval(3)
        sut.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/abc123")!])
        scheduled.value.first?.action()
        
        // then
        #expect(orderedOut.value.isEmpty)
    }
    
    // MARK: - MS-APP-2: last window closing
    
    @Test func givenTheLastWindowCloses_whenAsked_thenTheAppDoesNotTerminate() {
        // given
        let (sut, _, _, _) = makeSUT()
        
        // when — `NSApplication.shared`, not the bare `NSApp` global: in this test process (no real
        // `NSApplicationMain` ever ran) `NSApp` is an implicitly-unwrapped optional that is only set
        // as a side effect of `NSApplication.shared` being accessed at least once, and depending on
        // test-execution order that may not have happened yet — a real, reproducible crash caught
        // while running this suite in parallel with the others.
        let shouldTerminate = sut.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        
        // then
        #expect(!shouldTerminate)
    }
    
    // MARK: - F4-29: notification delegate only for a `.app` bundle
    
    @Test func givenARealApp_whenLaunched_thenTheNotificationDelegateIsSet() {
        // given
        let (sut, _, _, _) = makeSUT()
        let setDelegateCalls = LockedBox(0)
        sut.isRunningAsApp = { true }
        sut.setNotificationDelegate = { _ in setDelegateCalls.value += 1 }
        
        // when
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        
        // then
        #expect(setDelegateCalls.value == 1)
    }
    
    @Test func givenABareBinary_whenLaunched_thenNoNotificationDelegateIsSet() {
        // given
        let (sut, _, _, _) = makeSUT()
        let setDelegateCalls = LockedBox(0)
        sut.isRunningAsApp = { false }
        sut.setNotificationDelegate = { _ in setDelegateCalls.value += 1 }
        
        // when
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        
        // then
        #expect(setDelegateCalls.value == 0)
    }
    
    // MARK: - MS-LIST-1/F4-01: the app shell's own thin duty
    
    @Test func givenAppLaunch_whenStarting_thenDiscoveryRunsBeforeTheFirstListWhichRunsBeforeWatching() {
        // given — the ordering guarantee itself is `PbRepository.TaskListRepositoryImpl.start()`'s
        // own, already-tested contract; this proves only that the app shell actually calls it once
        // at launch, which is the one thing that lives here.
        let (sut, _, _, _) = makeSUT()
        let startCalls = LockedBox(0)
        sut.startTaskListing = { startCalls.value += 1 }
        
        // when
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))
        
        // then
        #expect(startCalls.value == 1)
    }

    // MARK: - Monitor piece 6: the backends catalog's own startup fetch and activation refresh

    @Test func givenAppLaunch_whenStarting_thenTheBackendsCatalogStartsOnce() {
        // given — same shape as `startTaskListing` above: the coalescing/discovery ordering itself is
        // `PbRepository.BackendsRepositoryImpl.start()`'s own tested contract; this proves only that
        // the app shell calls it once at launch.
        let (sut, _, _, _) = makeSUT()
        let startCalls = LockedBox(0)
        sut.startBackendsCatalog = { startCalls.value += 1 }

        // when
        sut.applicationDidFinishLaunching(Notification(name: .init("launch")))

        // then
        #expect(startCalls.value == 1)
    }

    @Test func givenAppActivation_whenObserved_thenItForwardsToTheBackendsCatalog() {
        // given — the 60 s bound is `BackendsRepositoryImpl`'s own concern; this only proves the app
        // shell forwards every activation unconditionally.
        let (sut, _, _, _) = makeSUT()
        let activateCalls = LockedBox(0)
        sut.notifyBackendsAppActive = { activateCalls.value += 1 }

        // when
        sut.applicationDidBecomeActive(Notification(name: .init("didBecomeActive")))
        sut.applicationDidBecomeActive(Notification(name: .init("didBecomeActive")))

        // then
        #expect(activateCalls.value == 2)
    }

    // MARK: - MS-APP-3: notification click
    
    //
    // `UNNotificationResponse`/`UNNotification` have no public initializer, so these drive
    // `AppDelegate.handleNotificationClick(userInfo:)` directly — the pure helper pulled out of
    // `userNotificationCenter(_:didReceive:withCompletionHandler:)` for exactly this reason.
    
    @Test func givenAValidNotificationID_whenClicked_thenItSelectsAndOpensTheWindowRegardlessOfTheToggle() {
        // given
        let (sut, _, _, _) = makeSUT()
        let coordinator = MockCoordinator()
        let handledPaths = LockedBox<[String]>([])
        given(coordinator).handle(path: .any).willProduce { path in
            if let destination = path as? MonitorDestination { handledPaths.value.append(destination.pathId) }
        }
        sut.coordinator = coordinator
        
        // when
        sut.handleNotificationClick(userInfo: ["task_id": "abc123"])
        
        // then — `.task` selects, then `.openWindow` unconditionally, in that order.
        #expect(handledPaths.value == [MonitorDestination.task("abc123").pathId, MonitorDestination.openWindow.pathId])
    }
    
    @Test func givenAnInvalidNotificationID_whenClicked_thenNothingIsSelected() {
        // given
        let (sut, _, _, _) = makeSUT()
        let coordinator = MockCoordinator()
        given(coordinator).handle(path: .any).willReturn()
        sut.coordinator = coordinator
        
        // when
        sut.handleNotificationClick(userInfo: ["task_id": "not a valid id!"])
        
        // then
        verify(coordinator).handle(path: .any).called(0)
    }
    
    @Test func givenNoTaskIDAtAll_whenClicked_thenNothingIsSelected() {
        // given
        let (sut, _, _, _) = makeSUT()
        let coordinator = MockCoordinator()
        given(coordinator).handle(path: .any).willReturn()
        sut.coordinator = coordinator
        
        // when
        sut.handleNotificationClick(userInfo: [:])
        
        // then
        verify(coordinator).handle(path: .any).called(0)
    }
    
    // MARK: - Foreground notifications show banner + sound

    @Test func givenAForegroundNotification_whenPresented_thenItShowsBannerAndSound() {
        // given
        let (sut, _, _, _) = makeSUT()

        // when
        let options = sut.foregroundPresentationOptions()

        // then
        #expect(options == [.banner, .sound])
    }

    // MARK: - Decision 3: applicationShouldHandleReopen

    //
    // Decided from the `mainWindows()` seam alone, never from `hasVisibleWindows` — that flag is
    // `true` whenever *any* window (Settings, the menu-bar panel) is on screen, which says nothing
    // about the main window. `VisibilityFakeWindow` stands in for a real `NSWindow` because
    // `isVisible`/`isMiniaturized` are not reliably drivable on a real, never-ordered-front window in
    // a headless test run.

    @Test func givenNoMainWindow_whenReopenIsRequested_thenItOpensTheWindowOnceAndReturnsTrue() {
        // given
        let (sut, _, _, _) = makeSUT()
        sut.mainWindows = { [] }
        let (coordinator, handledPaths) = Self.makeReopenCoordinator()
        sut.coordinator = coordinator

        // when
        let result = sut.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        // then
        #expect(result)
        #expect(handledPaths.value == [MonitorDestination.openWindow.pathId])
    }

    @Test func givenAVisibleMainWindow_whenReopenIsRequested_thenNothingExtraHappensAndItReturnsTrue() {
        // given
        let (sut, _, _, _) = makeSUT()
        let window = VisibilityFakeWindow(isVisible: true, isMiniaturized: false)
        sut.mainWindows = { [window] }
        let coordinator = MockCoordinator()
        given(coordinator).handle(path: .any).willReturn()
        sut.coordinator = coordinator

        // when
        let result = sut.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)

        // then
        #expect(result)
        verify(coordinator).handle(path: .any).called(0)
    }

    @Test func givenOnlyASettingsWindowIsVisible_whenReopenIsRequested_thenTheFlagIsIgnoredAndTheWindowOpens() {
        // given — `hasVisibleWindows` is `true` (Settings is open), but `mainWindows()` is empty:
        // the flag alone would say "do nothing", which is exactly the case this seam avoids.
        let (sut, _, _, _) = makeSUT()
        sut.mainWindows = { [] }
        let (coordinator, handledPaths) = Self.makeReopenCoordinator()
        sut.coordinator = coordinator

        // when
        let result = sut.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)

        // then
        #expect(result)
        #expect(handledPaths.value == [MonitorDestination.openWindow.pathId])
    }

    @Test func givenAMiniaturizedMainWindow_whenReopenIsRequested_thenItOpensTheWindow() {
        // given
        let (sut, _, _, _) = makeSUT()
        let window = VisibilityFakeWindow(isVisible: true, isMiniaturized: true)
        sut.mainWindows = { [window] }
        let (coordinator, handledPaths) = Self.makeReopenCoordinator()
        sut.coordinator = coordinator

        // when
        let result = sut.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true)

        // then
        #expect(result)
        #expect(handledPaths.value == [MonitorDestination.openWindow.pathId])
    }

    @Test func givenAnOrderedOutMainWindow_whenReopenIsRequested_thenItOpensTheWindow() {
        // given — visible == false (ordered out), not miniaturized.
        let (sut, _, _, _) = makeSUT()
        let window = VisibilityFakeWindow(isVisible: false, isMiniaturized: false)
        sut.mainWindows = { [window] }
        let (coordinator, handledPaths) = Self.makeReopenCoordinator()
        sut.coordinator = coordinator

        // when
        let result = sut.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        // then
        #expect(result)
        #expect(handledPaths.value == [MonitorDestination.openWindow.pathId])
    }

    // MARK: - Reopen test support

    private static func makeReopenCoordinator() -> (MockCoordinator, LockedBox<[String]>) {
        let coordinator = MockCoordinator()
        let handledPaths = LockedBox<[String]>([])
        given(coordinator).handle(path: .any).willProduce { path in
            if let destination = path as? MonitorDestination { handledPaths.value.append(destination.pathId) }
        }
        return (coordinator, handledPaths)
    }
}

/// A test double standing in for a real `NSWindow` — `isVisible`/`isMiniaturized` on a genuine
/// `NSWindow` that has never been ordered front are not reliably drivable in a headless test run, so
/// this overrides both directly instead.
private final class VisibilityFakeWindow: NSWindow {
    private let visibleOverride: Bool
    private let miniaturizedOverride: Bool

    init(isVisible: Bool, isMiniaturized: Bool) {
        self.visibleOverride = isVisible
        self.miniaturizedOverride = isMiniaturized
        super.init(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        identifier = NSUserInterfaceItemIdentifier("main")
    }

    override var isVisible: Bool { visibleOverride }
    override var isMiniaturized: Bool { miniaturizedOverride }
}
