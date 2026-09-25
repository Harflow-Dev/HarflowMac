//
//  AppCoordinatorTests.swift
//  PolybridgeMonitorTests
//
//  F7 ("the seam itself — PbCommon.WindowPresenting + AppCoordinator.handle(path:) enumerating
//  MonitorDestination — is a Phase 5 coordinator test"), F4-24 (showWindow ordering), and MS-APP-4's
//  URL/toggle interaction.
//

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
            activateApp: { activateLog.value.append("activate") }
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
        
        // when
        let sessionID = UUID()
        sut.handle(path: MonitorDestination.interactive(sessionID))
        // then
        #expect(fakeMainWindow.selection == .interactive(sessionID))
        
        // when
        sut.handle(path: MonitorDestination.newSession)
        // then
        #expect(fakeMainWindow.isNewSessionPresented)
        
        // when — `.openWindow` never reaches `MainWindowCoordinator` at all; it is handled by
        // `AppCoordinator` itself via `WindowPresenting`.
        sut.handle(path: MonitorDestination.openWindow)
        // then
        #expect(openerCallCount == 1)
        #expect(!fakeMainWindow.handledDestinations.contains(.openWindow))
        #expect(fakeMainWindow.handledDestinations == [.task("abc123"), .group("release"), .interactive(sessionID), .newSession])
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
        // given
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
        // given
        let (sut, fakeMainWindow, taskList, _) = makeSUT()
        
        // when
        let handled = sut.handle(url: URL(string: "https://example.com")!)
        
        // then
        #expect(!handled)
        #expect(fakeMainWindow.selection == nil)
        verify(taskList).refresh().called(0)
    }
    
    @Test func givenAURLSelectsATask_whenOpenWindowOnStartIsOff_thenTheWindowDoesNotComeForward() async {
        // given
        let activateLog = LockedBox<[String]>([])
        let refreshCalled = LockedBox(false)
        let (sut, fakeMainWindow, taskList, _) = makeSUT(openWindowOnStart: false, refreshCalled: refreshCalled, activateLog: activateLog)
        
        // when
        let handled = sut.handle(url: URL(string: "polybridge-monitor://task/abc123")!)
        
        // then
        #expect(handled)
        #expect(fakeMainWindow.selection == .task("abc123"))
        await verify(taskList).refresh().calledEventually(1, before: .seconds(1))
        #expect(activateLog.value.isEmpty)
    }
    
    @Test func givenAURLSelectsATask_whenOpenWindowOnStartIsOn_thenTheWindowComesForward() {
        // given
        let activateLog = LockedBox<[String]>([])
        let (sut, fakeMainWindow, _, _) = makeSUT(openWindowOnStart: true, activateLog: activateLog)
        
        // when
        let handled = sut.handle(url: URL(string: "polybridge-monitor://task/abc123")!)
        
        // then
        #expect(handled)
        #expect(fakeMainWindow.selection == .task("abc123"))
        #expect(activateLog.value == ["activate"])
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
