//
//  AppDelegateSingleInstanceTests.swift
//  PolybridgeMonitorTests
//
//  Monitor piece 9 (`.claude/plans/2026-09-27-monitor-p9-single-instance.md`): the
//  `AppDelegate`-level wiring around `SingleInstanceGuard` — detection is covered separately in
//  `SingleInstanceGuardTests`. Every AppKit touch point (`NSWorkspace.open`/`openApplication`,
//  `NSApp.terminate`, the deadline/rehide timers) goes through `AppDelegate`'s injected seams, so
//  nothing here waits on a real timer or calls real AppKit.
//

import AppKit
import Foundation
import Mockable
import PbCommon
import PbCommonTestMock
@testable import PolybridgeMonitor
import Testing

@MainActor
@Suite struct AppDelegateSingleInstanceTests {

    private static let selfBundleIdentifier = "dev.polybridge.monitor"
    private static let selfBundleURL = URL(fileURLWithPath: "/Applications/Polybridge Monitor.app")
    private static let otherBundleURL = URL(fileURLWithPath: "/Users/example/Applications/Polybridge Monitor.app")

    // MARK: - Helpers

    private struct SUT {
        let sut: AppDelegate
        let scheduled: LockedBox<[(delay: TimeInterval, action: @MainActor () -> Void)]>
        let orderedOutWindows: LockedBox<[NSWindow]>
        let startTaskListingCalls: LockedBox<Int>
        let setNotificationDelegateCalls: LockedBox<Int>
        let forwardCalls: LockedBox<[(urls: [URL], bundleURL: URL, configuration: NSWorkspace.OpenConfiguration)]>
        let forwardCompletions: LockedBox<[@MainActor (Result<Void, Error>) -> Void]>
        let reopenCalls: LockedBox<[(bundleURL: URL, configuration: NSWorkspace.OpenConfiguration)]>
        let reopenCompletions: LockedBox<[@MainActor (Result<Void, Error>) -> Void]>
        let terminateCallCount: LockedBox<Int>
    }

    private func makeSUT(runningApps: [RunningAppSnapshot] = []) -> SUT {
        let sut = AppDelegate()
        let scheduled = LockedBox<[(delay: TimeInterval, action: @MainActor () -> Void)]>([])
        let orderedOutWindows = LockedBox<[NSWindow]>([])
        let startTaskListingCalls = LockedBox(0)
        let setNotificationDelegateCalls = LockedBox(0)
        let forwardCalls = LockedBox<[(urls: [URL], bundleURL: URL, configuration: NSWorkspace.OpenConfiguration)]>([])
        let forwardCompletions = LockedBox<[@MainActor (Result<Void, Error>) -> Void]>([])
        let reopenCalls = LockedBox<[(bundleURL: URL, configuration: NSWorkspace.OpenConfiguration)]>([])
        let reopenCompletions = LockedBox<[@MainActor (Result<Void, Error>) -> Void]>([])
        let terminateCallCount = LockedBox(0)

        sut.now = { Date() }
        sut.scheduleAfter = { delay, action in scheduled.value.append((delay, action)) }
        sut.isRunningAsApp = { true }
        sut.mainWindows = { [] }
        sut.orderOutWindow = { orderedOutWindows.value.append($0) }
        sut.setNotificationDelegate = { _ in setNotificationDelegateCalls.value += 1 }
        sut.startTaskListing = { startTaskListingCalls.value += 1 }
        sut.openWindowOnStart = { true }

        sut.runningApplications = { runningApps }
        sut.selfBundleIdentifier = { Self.selfBundleIdentifier }
        sut.selfBundleURL = { Self.selfBundleURL }
        sut.selfProcessIdentifier = { 111 }
        sut.selfLaunchDate = { Date(timeIntervalSince1970: 1) }

        sut.forwardURLs = { urls, bundleURL, configuration, completion in
            forwardCalls.value.append((urls, bundleURL, configuration))
            forwardCompletions.value.append(completion)
        }
        sut.requestReopen = { bundleURL, configuration, completion in
            reopenCalls.value.append((bundleURL, configuration))
            reopenCompletions.value.append(completion)
        }
        sut.terminateApp = { terminateCallCount.value += 1 }

        return SUT(
            sut: sut, scheduled: scheduled, orderedOutWindows: orderedOutWindows,
            startTaskListingCalls: startTaskListingCalls, setNotificationDelegateCalls: setNotificationDelegateCalls,
            forwardCalls: forwardCalls, forwardCompletions: forwardCompletions,
            reopenCalls: reopenCalls, reopenCompletions: reopenCompletions, terminateCallCount: terminateCallCount
        )
    }

    @Test func givenTwoConcurrentCopies_whenBothLaunch_thenOnlyTheNewerCopyTerminates() {
        // given
        let first = makeSUT()
        let second = makeSUT()
        let firstApp = RunningAppSnapshot(
            bundleIdentifier: Self.selfBundleIdentifier, bundleURL: Self.selfBundleURL,
            isTerminated: false, processIdentifier: 111, launchDate: Date(timeIntervalSince1970: 0)
        )
        var secondApp = duplicateSnapshot()
        secondApp.launchDate = Date(timeIntervalSince1970: 1)
        first.sut.selfLaunchDate = { firstApp.launchDate }
        second.sut.selfProcessIdentifier = { secondApp.processIdentifier }
        second.sut.selfBundleURL = { secondApp.bundleURL }
        second.sut.selfLaunchDate = { secondApp.launchDate }
        first.sut.runningApplications = { [secondApp, firstApp] }
        second.sut.runningApplications = { [firstApp, secondApp] }

        // when — both inspect each other before either finishes launching.
        let notification = Notification(name: .init("launch"))
        first.sut.applicationWillFinishLaunching(notification)
        second.sut.applicationWillFinishLaunching(notification)
        first.sut.applicationDidFinishLaunching(notification)
        second.sut.applicationDidFinishLaunching(notification)
        second.scheduled.value.first(where: { $0.delay == 0 })?.action()
        second.reopenCompletions.value.first?(.success(()))

        // then
        #expect(first.sut.singleInstanceState.isPrimaryInstance)
        #expect(first.startTaskListingCalls.value == 1)
        #expect(first.terminateCallCount.value == 0)
        #expect(!second.sut.singleInstanceState.isPrimaryInstance)
        #expect(second.startTaskListingCalls.value == 0)
        #expect(second.reopenCalls.value.first?.bundleURL == Self.selfBundleURL)
        #expect(second.terminateCallCount.value == 1)
    }

    private func duplicateSnapshot(pid: pid_t = 222) -> RunningAppSnapshot {
        RunningAppSnapshot(
            bundleIdentifier: Self.selfBundleIdentifier, bundleURL: Self.otherBundleURL,
            isTerminated: false, processIdentifier: pid, launchDate: Date(timeIntervalSince1970: 0)
        )
    }

    private func launch() -> Notification { Notification(name: .init("launch")) }

    /// Fires the scheduled "one run-loop turn" check (delay `0`) that decides plain-launch vs.
    /// URL-launch — mirroring what a real run loop does between `applicationDidFinishLaunching`
    /// and any `application(_:open:)` batch AppKit still has queued.
    private func fireRunLoopTurnCheck(_ context: SUT) {
        context.scheduled.value.first { $0.delay == 0 }?.action()
    }

    // MARK: - No other instance: normal launch unchanged

    @Test func givenNoOtherRunningInstance_whenWillFinishLaunching_thenItIsNotADuplicate() {
        // given
        let context = makeSUT(runningApps: [])

        // when
        context.sut.applicationWillFinishLaunching(launch())

        // then
        #expect(context.sut.singleInstanceState.isPrimaryInstance)
    }

    @Test func givenNoOtherRunningInstance_whenLaunching_thenListingNotificationsAndTheTimerRunAsNormal() {
        // given
        let context = makeSUT(runningApps: [])
        context.sut.applicationWillFinishLaunching(launch())

        // when
        context.sut.applicationDidFinishLaunching(launch())

        // then — unchanged from the pre-piece-9 behaviour.
        #expect(context.startTaskListingCalls.value == 1)
        #expect(context.setNotificationDelegateCalls.value == 1)
        #expect(context.scheduled.value.map(\.delay) == [0.8])
        #expect(context.sut.singleInstanceState.isPrimaryInstance)
        #expect(context.terminateCallCount.value == 0)
    }

    // MARK: - Duplicate detected: skip listing/notifications/timer, hide the menu bar

    @Test func givenAnotherInstanceAtADifferentPath_whenWillFinishLaunching_thenItIsADuplicateAndTheMenuBarFlagFlips() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])

        // when
        context.sut.applicationWillFinishLaunching(launch())

        // then
        #expect(!context.sut.singleInstanceState.isPrimaryInstance)
    }

    @Test func givenADuplicateAtLaunch_whenDidFinishLaunching_thenListingNotificationsAndTheNormalTimerAreSkipped() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())

        // when
        context.sut.applicationDidFinishLaunching(launch())

        // then
        #expect(context.startTaskListingCalls.value == 0)
        #expect(context.setNotificationDelegateCalls.value == 0)
        #expect(!context.scheduled.value.map(\.delay).contains(0.8))
    }

    @Test func givenADuplicateAtLaunch_whenDidFinishLaunching_thenADeadlineAndARehideAreScheduled() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())

        // when
        context.sut.applicationDidFinishLaunching(launch())

        // then — the ~3 s bounded-exit deadline and the short rehide hop are both scheduled,
        // alongside the one-run-loop-turn check.
        #expect(context.scheduled.value.map(\.delay).sorted() == [0, 0.05, 3.0])
    }

    @Test func givenADuplicateWithAVisibleMainWindow_whenDidFinishLaunching_thenTheWindowIsOrderedOutImmediatelyAndOnEachRehide() {
        // given
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.mainWindows = { [window] }
        context.sut.applicationWillFinishLaunching(launch())

        // when
        context.sut.applicationDidFinishLaunching(launch())

        // then — ordered out immediately…
        #expect(context.orderedOutWindows.value.count == 1)

        // …and again on each 0.05 s rehide hop, for a window SwiftUI mounts afterward.
        context.scheduled.value.first { $0.delay == 0.05 }?.action()
        #expect(context.orderedOutWindows.value.count == 2)
    }

    @Test func givenTerminationHasHappened_whenTheRehideHopFires_thenItStopsRehidingAndDoesNotRescheduleItself() {
        // given
        let window = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: false)
        window.identifier = NSUserInterfaceItemIdentifier("main")
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.mainWindows = { [window] }
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        let scheduledCountBeforeDeadline = context.scheduled.value.count

        // when — the bounded-exit deadline fires, terminating the app…
        context.scheduled.value.first { $0.delay == 3.0 }?.action()
        // …and then the rehide hop that was already scheduled fires too.
        context.scheduled.value.first { $0.delay == 0.05 }?.action()

        // then — no further window ordering, and no further rehide scheduled.
        #expect(context.orderedOutWindows.value.count == 1)
        #expect(context.scheduled.value.count == scheduledCountBeforeDeadline)
    }

    // MARK: - URL forwarding

    @Test func givenADuplicateWithABufferedURL_whenApplicationOpenIsCalled_thenItIsForwardedWithTheExactConfiguration() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        let url = URL(string: "polybridge-monitor://task/abc123")!

        // when
        context.sut.application(NSApplication.shared, open: [url])

        // then
        #expect(context.forwardCalls.value.count == 1)
        let call = context.forwardCalls.value[0]
        #expect(call.urls == [url])
        #expect(call.bundleURL == Self.otherBundleURL)
        #expect(call.configuration.activates == false)
        #expect(call.configuration.allowsRunningApplicationSubstitution == false)
        #expect(call.configuration.createsNewApplicationInstance == false)
        // Not yet terminated — only after the forward's own completion.
        #expect(context.terminateCallCount.value == 0)
    }

    @Test func givenAForwardedURL_whenItsCompletionFires_thenItTerminates() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        context.sut.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/abc123")!])

        // when
        context.forwardCompletions.value.first?(.success(()))

        // then
        #expect(context.terminateCallCount.value == 1)
    }

    @Test func givenAForwardedURLFails_whenItsCompletionFires_thenItStillTerminates() {
        // given
        struct SomeError: Error {}
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        context.sut.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/abc123")!])

        // when
        context.forwardCompletions.value.first?(.failure(SomeError()))

        // then
        #expect(context.terminateCallCount.value == 1)
    }

    @Test func givenSeveralURLBatches_whenEachArrives_thenEachIsForwardedAndTerminationWaitsForAllCompletions() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        let firstURL = URL(string: "polybridge-monitor://task/first")!
        let secondURL = URL(string: "polybridge-monitor://task/second")!

        // when — two separate batches, arriving one after another.
        context.sut.application(NSApplication.shared, open: [firstURL])
        context.sut.application(NSApplication.shared, open: [secondURL])

        // then — both forwarded, no termination yet.
        #expect(context.forwardCalls.value.map(\.urls) == [[firstURL], [secondURL]])
        #expect(context.terminateCallCount.value == 0)

        // when — only the first batch's forward completes.
        context.forwardCompletions.value[0](.success(()))

        // then — still not terminated: the second forward is still outstanding.
        #expect(context.terminateCallCount.value == 0)

        // when — the second batch's forward completes too.
        context.forwardCompletions.value[1](.success(()))

        // then
        #expect(context.terminateCallCount.value == 1)
    }

    // MARK: - Plain launch: reopen request

    @Test func givenAPlainDuplicateLaunch_whenOneRunLoopTurnPasses_thenAReopenRequestIsSentWithTheExactConfiguration() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())

        // when — no URL arrived; the one-run-loop-turn check fires.
        fireRunLoopTurnCheck(context)

        // then
        #expect(context.reopenCalls.value.count == 1)
        let call = context.reopenCalls.value[0]
        #expect(call.bundleURL == Self.otherBundleURL)
        #expect(call.configuration.activates == true)
        #expect(call.configuration.allowsRunningApplicationSubstitution == false)
        #expect(call.configuration.createsNewApplicationInstance == false)
        // Never a bare `NSRunningApplication.activate` / forward-with-no-URLs: `requestReopen`
        // (not `forwardURLs`) is the only seam called.
        #expect(context.forwardCalls.value.isEmpty)
        #expect(context.terminateCallCount.value == 0)
    }

    @Test func givenTheReopenRequestCompletes_whenNoLateURLArrived_thenItTerminates() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        fireRunLoopTurnCheck(context)

        // when
        context.reopenCompletions.value.first?(.success(()))

        // then
        #expect(context.terminateCallCount.value == 1)
    }

    @Test func givenAURLArrivedBeforeTheRunLoopTurnCheck_whenItFires_thenNoReopenIsSent() {
        // given — a URL delivered within the same turn already forwarded; the plain-launch check
        // must not also send a reopen for the same launch.
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        context.sut.application(NSApplication.shared, open: [URL(string: "polybridge-monitor://task/abc123")!])

        // when
        fireRunLoopTurnCheck(context)

        // then
        #expect(context.reopenCalls.value.isEmpty)
        #expect(context.forwardCalls.value.count == 1)
    }

    @Test func givenAReopenWasSentButNotYetCompleted_whenALateURLArrives_thenItIsStillForwardedBeforeTerminating() {
        // given — the reopen is in flight (its completion not yet invoked).
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        fireRunLoopTurnCheck(context)
        #expect(context.reopenCalls.value.count == 1)

        // when — a URL arrives late, before the reopen's own completion.
        let lateURL = URL(string: "polybridge-monitor://task/late")!
        context.sut.application(NSApplication.shared, open: [lateURL])

        // then — forwarded immediately.
        #expect(context.forwardCalls.value.map(\.urls) == [[lateURL]])

        // when — the reopen completes first…
        context.reopenCompletions.value.first?(.success(()))

        // then — not terminated yet: the late forward is still outstanding.
        #expect(context.terminateCallCount.value == 0)

        // when — …then the late forward completes too.
        context.forwardCompletions.value.first?(.success(()))

        // then
        #expect(context.terminateCallCount.value == 1)
    }

    // MARK: - Bounded exit: the deadline

    @Test func givenNoCompletionEverArrives_whenTheDeadlineFires_thenItTerminatesAnyway() {
        // given — a reopen sent, but its completion never invoked.
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        fireRunLoopTurnCheck(context)
        #expect(context.terminateCallCount.value == 0)

        // when
        context.scheduled.value.first { $0.delay == 3.0 }?.action()

        // then
        #expect(context.terminateCallCount.value == 1)
    }

    @Test func givenTheDeadlineAlreadyFired_whenALateCompletionArrives_thenItDoesNotTerminateTwice() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        context.sut.applicationDidFinishLaunching(launch())
        fireRunLoopTurnCheck(context)
        context.scheduled.value.first { $0.delay == 3.0 }?.action()
        #expect(context.terminateCallCount.value == 1)

        // when — the reopen's completion turns up afterward.
        context.reopenCompletions.value.first?(.success(()))

        // then — still exactly one termination.
        #expect(context.terminateCallCount.value == 1)
    }

    // MARK: - Reopen never handled locally

    @Test func givenADuplicateInstance_whenReopenIsRequestedBySystem_thenItIsNeverHandledLocally() {
        // given
        let context = makeSUT(runningApps: [duplicateSnapshot()])
        context.sut.applicationWillFinishLaunching(launch())
        let coordinator = MockCoordinator()
        given(coordinator).handle(path: .any).willReturn()
        context.sut.coordinator = coordinator

        // when
        let result = context.sut.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: false)

        // then
        #expect(result)
        verify(coordinator).handle(path: .any).called(0)
    }
}
