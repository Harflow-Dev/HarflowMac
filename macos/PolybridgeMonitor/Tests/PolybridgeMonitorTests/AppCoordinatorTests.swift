//
//  AppCoordinatorTests.swift
//  PolybridgeMonitorTests
//
//  F7 ("the seam itself — PbCommon.WindowPresenting + AppCoordinator.handle(path:) enumerating
//  MonitorDestination — is a Phase 5 coordinator test"), F4-24 (showWindow ordering), and MS-APP-4's
//  URL/toggle interaction.
//

import AppKit
import Foundation
import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbCommonTestMock
import PbRepository
@testable import PolybridgeMonitor
import Testing

@MainActor
@Suite struct AppCoordinatorTests {
    
    // MARK: - Helpers
    
    private func makeSUT(
        openWindowOnStart: Bool = true,
        mainWindowVisible: Bool = false,
        refreshCalled: LockedBox<Bool> = LockedBox(false),
        activateLog: LockedBox<[String]> = LockedBox([])
    ) -> (sut: AppCoordinator, fakeMainWindow: FakeMainWindowNavigationCoordinator, taskList: MockTaskListRepository, settings: MockSettingsRepository) {
        let fakeParent = MockCoordinator()
        let fakeMainWindow = FakeMainWindowNavigationCoordinator(parent: fakeParent)

        let mainWindowFactory = MockMainWindowFeatureFactory()
        given(mainWindowFactory).makeMainWindowCoordinator(asChildOf: .any).willReturn(fakeMainWindow)

        let taskList = MockTaskListRepository()
        given(taskList).refresh().willProduce { refreshCalled.value = true }

        let settings = MockSettingsRepository()
        given(settings).openWindowOnStart.willReturn(openWindowOnStart)

        let sut = AppCoordinator(
            mainWindowFeatureFactory: mainWindowFactory,
            taskListRepository: taskList,
            settingsRepository: settings,
            activateApp: { activateLog.value.append("activate") },
            isMainWindowVisible: { mainWindowVisible }
        )
        return (sut, fakeMainWindow, taskList, settings)
    }
    
    // MARK: - handle(path:)
    
    @Test func givenEachMonitorDestination_whenHandled_thenItRoutesOrBubblesCorrectly() {
        // given
        let (sut, fakeMainWindow, _, _) = makeSUT()
        var openerCallCount = 0
        sut.registerWindowOpener { openerCallCount += 1 }

        // when
        sut.handle(path: MonitorDestination.task("abc123"))
        // then
        #expect(fakeMainWindow.selection == .task("abc123"))

        // when
        sut.handle(path: MonitorDestination.group("release"))
        // then
        #expect(fakeMainWindow.selection == .group("release"))

        // when — decision 5: `.newSession` also brings the window forward, so the opener now fires
        // here too, not only on `.openWindow`.
        sut.handle(path: MonitorDestination.newSession)
        // then
        #expect(fakeMainWindow.isNewSessionPresented)
        #expect(openerCallCount == 1)

        // when — `.openWindow` never reaches `MainWindowCoordinator` at all; it is handled by
        // `AppCoordinator` itself via `WindowPresenting`.
        sut.handle(path: MonitorDestination.openWindow)
        // then
        #expect(openerCallCount == 2)
        #expect(!fakeMainWindow.handledDestinations.contains(.openWindow))
        #expect(fakeMainWindow.handledDestinations == [.task("abc123"), .group("release"), .newSession])
    }

    @Test func givenNewSessionDestination_whenHandled_thenActivateRunsBeforeTheOpenerWhichRunsBeforeForwarding() {
        // given — a shared event log proves the full ordering (F4-24 plus decision 5's ordering),
        // not just the end state: `activate` (via `activateApp`), then the captured opener, then the
        // forward to `MainWindowCoordinator` (via `FakeMainWindowNavigationCoordinator.onHandle`).
        let log = LockedBox<[String]>([])
        let (sut, fakeMainWindow, _, _) = makeSUT(activateLog: log)
        sut.registerWindowOpener { log.value.append("opener") }
        fakeMainWindow.onHandle = { destination in
            if destination.pathId == MonitorDestination.newSession.pathId { log.value.append("newSession") }
        }

        // when
        sut.handle(path: MonitorDestination.newSession)

        // then
        #expect(log.value == ["activate", "opener", "newSession"])
    }
    
    @Test func givenAPathThatIsNotAMonitorDestination_whenHandled_thenNothingHappens() {
        // given
        let (sut, fakeMainWindow, _, _) = makeSUT()
        
        // when
        sut.handle(path: NotAMonitorDestination())
        
        // then
        #expect(fakeMainWindow.handledDestinations.isEmpty)
        #expect(fakeMainWindow.selection == nil)
    }
    
    // MARK: - showWindow ordering (F4-24)

    @Test func givenShowWindow_whenCalled_thenActivateRunsBeforeTheCapturedOpener() {
        // given — `registerWindowOpener` is called directly on `AppCoordinator`, exactly as the
        // scene-root adapter (`MainWindowSceneRoot`, decision 3) does; never through
        // `MenuBarCoordinator`. This proves `showWindow()` works from that path alone.
        let activateLog = LockedBox<[String]>([])
        let (sut, _, _, _) = makeSUT(activateLog: activateLog)
        sut.registerWindowOpener { activateLog.value.append("opener") }
        
        // when
        sut.handle(path: MonitorDestination.openWindow)
        
        // then
        #expect(activateLog.value == ["activate", "opener"])
    }
    
    @Test func givenNoOpenerRegisteredYet_whenShowWindowRuns_thenActivateStillHappens() {
        // given
        let activateLog = LockedBox<[String]>([])
        let (sut, _, _, _) = makeSUT(activateLog: activateLog)
        
        // when
        sut.handle(path: MonitorDestination.openWindow)
        
        // then
        #expect(activateLog.value == ["activate"])
    }
    
    // MARK: - handle(url:) (MS-APP-4)

    @Test func givenAnInvalidURL_whenHandled_thenItIsIgnored() {
        // given — visibility is irrelevant to an invalid URL, but stated explicitly per the piece 10
        // test spec ("existing URL tests: make each state its visibility explicitly").
        let (sut, fakeMainWindow, taskList, _) = makeSUT(mainWindowVisible: false)

        // when
        let handled = sut.handle(url: URL(string: "https://example.com")!)

        // then
        #expect(!handled)
        #expect(fakeMainWindow.selection == nil)
        verify(taskList).refresh().called(0)
    }

    @Test func givenAURLSelectsATask_whenWindowNotVisibleAndOpenWindowOnStartIsOff_thenTheWindowDoesNotComeForward() async {
        // given
        let activateLog = LockedBox<[String]>([])
        let refreshCalled = LockedBox(false)
        let (sut, fakeMainWindow, taskList, _) = makeSUT(
            openWindowOnStart: false, mainWindowVisible: false, refreshCalled: refreshCalled, activateLog: activateLog
        )

        // when
        let handled = sut.handle(url: URL(string: "polybridge-monitor://task/abc123")!)

        // then — selects (+ reveals, via `handle(path:)`), refreshes, but never activates.
        #expect(handled)
        #expect(fakeMainWindow.selection == .task("abc123"))
        #expect(fakeMainWindow.handledDestinations == [.task("abc123")])
        await verify(taskList).refresh().calledEventually(1, before: .seconds(1))
        #expect(activateLog.value.isEmpty)
    }

    @Test func givenAURLSelectsATask_whenWindowNotVisibleAndOpenWindowOnStartIsOn_thenTheWindowComesForward() {
        // given
        let activateLog = LockedBox<[String]>([])
        let (sut, fakeMainWindow, _, _) = makeSUT(openWindowOnStart: true, mainWindowVisible: false, activateLog: activateLog)

        // when
        let handled = sut.handle(url: URL(string: "polybridge-monitor://task/abc123")!)

        // then — select (+ reveal), then activate before the opener (F4-24 ordering).
        #expect(handled)
        #expect(fakeMainWindow.selection == .task("abc123"))
        #expect(activateLog.value == ["activate"])
    }

    @Test func givenAValidURLAndTheWindowNotVisible_whenHandled_thenItGoesThroughTheMainWindowsHandlePathSoTheSidebarRevealsIt() {
        // given — a direct `selection` write would skip the reveal request that `handle(path:)`
        // makes, leaving a task opened by URL hidden inside a collapsed parent.
        let (sut, fakeMainWindow, _, _) = makeSUT(openWindowOnStart: false, mainWindowVisible: false)

        // when
        sut.handle(url: URL(string: "polybridge-monitor://task/abc123")!)

        // then
        #expect(fakeMainWindow.handledDestinations == [.task("abc123")])
    }

    // MARK: - handle(url:), main window already visible (piece 10)

    //
    // The window is already on screen: the task link must only refresh the list in place — no
    // selection change (so no pending sidebar reveal either, since that request rides on the same
    // `handle(path:)` call), no activation, no opener call — regardless of the
    // "Open window when a task starts" toggle. Doing any of those to an already-open window is
    // exactly what made it "close and pop back" on every task start.

    @Test func givenAURLAndTheWindowIsVisible_whenOpenWindowOnStartIsOn_thenOnlyRefreshHappens() async {
        // given
        let activateLog = LockedBox<[String]>([])
        let refreshCalled = LockedBox(false)
        var openerCallCount = 0
        let (sut, fakeMainWindow, taskList, _) = makeSUT(
            openWindowOnStart: true, mainWindowVisible: true, refreshCalled: refreshCalled, activateLog: activateLog
        )
        sut.registerWindowOpener { openerCallCount += 1 }

        // when
        let handled = sut.handle(url: URL(string: "polybridge-monitor://task/abc123")!)

        // then — the fake `MainWindowCoordinator` never receives `handle(path:)` at all, so neither
        // `selection` nor the pending reveal changes.
        #expect(handled)
        #expect(fakeMainWindow.handledDestinations.isEmpty)
        #expect(fakeMainWindow.selection == nil)
        await verify(taskList).refresh().calledEventually(1, before: .seconds(1))
        #expect(activateLog.value.isEmpty)
        #expect(openerCallCount == 0)
    }

    @Test func givenAURLAndTheWindowIsVisible_whenOpenWindowOnStartIsOff_thenOnlyRefreshHappens() async {
        // given — same outcome as the toggle-on case above: visibility, not the toggle, decides.
        let activateLog = LockedBox<[String]>([])
        let refreshCalled = LockedBox(false)
        var openerCallCount = 0
        let (sut, fakeMainWindow, taskList, _) = makeSUT(
            openWindowOnStart: false, mainWindowVisible: true, refreshCalled: refreshCalled, activateLog: activateLog
        )
        sut.registerWindowOpener { openerCallCount += 1 }

        // when
        let handled = sut.handle(url: URL(string: "polybridge-monitor://task/abc123")!)

        // then
        #expect(handled)
        #expect(fakeMainWindow.handledDestinations.isEmpty)
        #expect(fakeMainWindow.selection == nil)
        await verify(taskList).refresh().calledEventually(1, before: .seconds(1))
        #expect(activateLog.value.isEmpty)
        #expect(openerCallCount == 0)
    }

    // MARK: - handle(path:) is unaffected by window visibility (notification-click path)

    @Test func givenTheLaunchURL_whenSwiftUIsInitialWindowIsAlreadyVisible_thenTheTaskIsStillSelected() {
        // given
        let activateLog = LockedBox<[String]>([])
        let (sut, fakeMainWindow, _, _) = makeSUT(openWindowOnStart: false, mainWindowVisible: true, activateLog: activateLog)

        // when
        let handled = sut.handleLaunchURL(URL(string: "polybridge-monitor://task/abc123")!)

        // then
        #expect(handled)
        #expect(fakeMainWindow.selection == .task("abc123"))
        #expect(activateLog.value.isEmpty)
    }

    @Test func givenTheLaunchURLAndOpenWindowOnStartIsOn_whenHandled_thenTheWindowComesForward() {
        // given
        let activateLog = LockedBox<[String]>([])
        let (sut, fakeMainWindow, _, _) = makeSUT(openWindowOnStart: true, mainWindowVisible: true, activateLog: activateLog)

        // when
        sut.handleLaunchURL(URL(string: "polybridge-monitor://task/abc123")!)

        // then
        #expect(fakeMainWindow.selection == .task("abc123"))
        #expect(activateLog.value == ["activate"])
    }

    @Test func givenAnInvalidLaunchURL_whenHandled_thenItIsIgnored() {
        // given
        let (sut, fakeMainWindow, _, _) = makeSUT(mainWindowVisible: true)

        // when
        let handled = sut.handleLaunchURL(URL(string: "https://example.com")!)

        // then
        #expect(!handled)
        #expect(fakeMainWindow.selection == nil)
    }

    @Test func givenTheNotificationClickPath_whenTheWindowIsAlreadyVisible_thenItStillSelectsAndShows() {
        // given — `AppDelegate.handleNotificationClick(userInfo:)` calls `handle(path:)` for `.task`
        // then `.openWindow` directly (F4-32), never `handle(url:)`; this proves that path ignores
        // `isMainWindowVisible` entirely, unlike `handle(url:)` above.
        let activateLog = LockedBox<[String]>([])
        var openerCallCount = 0
        let (sut, fakeMainWindow, _, _) = makeSUT(mainWindowVisible: true, activateLog: activateLog)
        sut.registerWindowOpener { openerCallCount += 1 }

        // when
        sut.handle(path: MonitorDestination.task("abc123"))
        sut.handle(path: MonitorDestination.openWindow)

        // then
        #expect(fakeMainWindow.selection == .task("abc123"))
        #expect(activateLog.value == ["activate"])
        #expect(openerCallCount == 1)
    }

    // MARK: - Cold launch through the real AppDelegate + AppCoordinator

    @Test func givenAColdLaunchByURL_whenARealAppDelegateAndCoordinatorHandleIt_thenTheTaskIsSelectedInTheRealMainWindowCoordinator() async {
        // given — a real `AppDelegate` and a real `AppCoordinator`, wired to the real
        // `MainWindowFeatureFactoryImpl` (its `makeMainWindowCoordinator(asChildOf:)` needs nothing
        // but a parent — no `GlobalValues` view repository involved), so this exercises the actual
        // cold-launch path end to end rather than only the fakes above. `isMainWindowVisible: false`
        // stands in for a window that has not been shown yet, exactly the state at launch.
        let refreshCalled = LockedBox(false)
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willProduce { refreshCalled.value = true }
        let settings = MockSettingsRepository()
        given(settings).openWindowOnStart.willReturn(true)

        let coordinator = AppCoordinator(
            mainWindowFeatureFactory: MainWindowFeatureFactoryImpl(),
            taskListRepository: taskList,
            settingsRepository: settings,
            activateApp: {},
            isMainWindowVisible: { false }
        )
        let delegate = AppDelegate()
        delegate.coordinator = coordinator

        // when
        delegate.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/abc123")!])

        // then
        #expect(coordinator.mainWindowNavigationCoordinator?.selection == .task("abc123"))
        await verify(taskList).refresh().calledEventually(1, before: .seconds(1))
    }

    /// A real delegate and coordinator with SwiftUI's initial window already on screen.
    private func makeLaunchedPair(launchIsDefault: Bool? = false) -> (delegate: AppDelegate, coordinator: AppCoordinator, clock: LockedBox<Date>) {
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willReturn()
        let settings = MockSettingsRepository()
        given(settings).openWindowOnStart.willReturn(false)
        let coordinator = AppCoordinator(
            mainWindowFeatureFactory: MainWindowFeatureFactoryImpl(),
            taskListRepository: taskList,
            settingsRepository: settings,
            activateApp: {},
            isMainWindowVisible: { true }
        )
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000_000))
        let delegate = AppDelegate()
        delegate.now = { clock.value }
        delegate.scheduleAfter = { _, _ in }
        delegate.isRunningAsApp = { false }
        delegate.startTaskListing = {}
        delegate.coordinator = coordinator
        let userInfo: [AnyHashable: Any]? = launchIsDefault.map { [NSApplication.launchIsDefaultUserInfoKey: $0] }
        delegate.applicationDidFinishLaunching(Notification(name: .init("launch"), userInfo: userInfo))
        return (delegate, coordinator, clock)
    }

    @Test func givenTheLaunchBatch_whenTheInitialWindowIsVisible_thenItsTaskIsSelected() {
        // given
        let (delegate, coordinator, clock) = makeLaunchedPair()
        clock.value = clock.value.addingTimeInterval(0.3)

        // when
        delegate.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/aaa111")!])

        // then
        #expect(coordinator.mainWindowNavigationCoordinator?.selection == .task("aaa111"))
    }

    @Test func givenASecondBatchWithinTwoSeconds_whenTheWindowIsVisible_thenTheSelectionIsLeftAlone() {
        // given
        let (delegate, coordinator, clock) = makeLaunchedPair()
        clock.value = clock.value.addingTimeInterval(0.3)
        delegate.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/aaa111")!])
        clock.value = clock.value.addingTimeInterval(1)

        // when
        delegate.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/bbb222")!])

        // then
        #expect(coordinator.mainWindowNavigationCoordinator?.selection == .task("aaa111"))
    }

    @Test func givenALaunchByHand_whenATaskStartsASecondLater_thenTheSelectionIsLeftAlone() {
        // given
        let (delegate, coordinator, clock) = makeLaunchedPair(launchIsDefault: true)
        clock.value = clock.value.addingTimeInterval(1)

        // when
        delegate.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/bbb222")!])

        // then
        #expect(coordinator.mainWindowNavigationCoordinator?.selection == nil)
    }

    @Test func givenNoLaunchKindReported_whenTheFirstBatchArrivesInTime_thenItsTaskIsSelected() {
        // given
        let (delegate, coordinator, clock) = makeLaunchedPair(launchIsDefault: nil)
        clock.value = clock.value.addingTimeInterval(0.3)

        // when
        delegate.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/aaa111")!])

        // then
        #expect(coordinator.mainWindowNavigationCoordinator?.selection == .task("aaa111"))
    }

    @Test func givenAFirstBatchAfterTheLaunchWindow_whenTheWindowIsVisible_thenTheSelectionIsLeftAlone() {
        // given — launched by hand; the first task starts later
        let (delegate, coordinator, clock) = makeLaunchedPair()
        clock.value = clock.value.addingTimeInterval(30)

        // when
        delegate.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/bbb222")!])

        // then
        #expect(coordinator.mainWindowNavigationCoordinator?.selection == nil)
    }
}

// MARK: - Test support

private struct NotAMonitorDestination: PathDestination {
    var pathId: String { "not-a-monitor-destination" }
}

/// A tiny `@unchecked Sendable` mutable box for capturing side effects from a `Mockable`
/// `willProduce`/closure callback, mirroring the `Box`/`LockedBox` pattern every other package in
/// this app already uses to work around Mockable's FIFO/re-`given` stubbing pitfall (see
/// `MainWindowFeature`'s `ParallelVMTests`).
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    
    init(_ initial: Value) { self.storage = initial }
    
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
