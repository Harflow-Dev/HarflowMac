import Foundation
import Observation
import PbCommon
@testable import PbUI
import Testing

@MainActor @Suite struct IncidentPresentationTests {
    @Test func givenDismissedFailure_whenPollingRepeats_thenDoesNotReappearUntilRecovery() {
        // given
        let state = IncidentPresentation()
        state.report(source: "list", message: "Failed")
        state.dismiss()
        // when
        state.report(source: "list", message: "Failed")
        // then
        #expect(state.current == nil)
        #expect(state.failures.count == 1)
        state.resolve(source: "list")
        state.report(source: "list", message: "Failed")
        #expect(state.current != nil)
    }

    @Test func givenMultipleSources_whenOneRecovers_thenOtherFailureRemains() {
        // given
        let state = IncidentPresentation()
        state.report(source: "list", message: "List failed")
        state.report(source: "detail", message: "Detail failed")
        // when
        state.resolve(source: "list")
        // then
        #expect(state.current?.source == "detail")
        #expect(state.failures.map(\.source) == ["detail"])
    }

    @Test func givenActiveNotification_whenInteractionPauses_thenDismissesAfterEightActiveSeconds() {
        // given
        let state = IncidentPresentation()
        let start = Date(timeIntervalSince1970: 0)
        state.report(source: "list", message: "Failed")
        state.tick(now: start, paused: false)
        // when
        state.tick(now: start.addingTimeInterval(3), paused: false)
        state.tick(now: start.addingTimeInterval(103), paused: true)
        state.report(source: "list", message: "Failed")
        state.tick(now: start.addingTimeInterval(107), paused: false)
        // then
        #expect(state.current != nil)
        #expect(state.remaining == 1)
        state.tick(now: start.addingTimeInterval(108), paused: false)
        #expect(state.current == nil)
        #expect(state.failures.count == 1)
    }

    @Test func givenNotification_whenDifferentFailureArrives_thenNewestReplacesAndResetsTimer() {
        // given
        let state = IncidentPresentation()
        state.report(source: "list", message: "Failed")
        // when
        state.report(source: "list", message: "Blocked")
        // then
        #expect(state.current?.message == "Blocked")
        #expect(state.remaining == 8)
        #expect(state.failures.count == 1)
    }

    @Test(arguments: [true, false])
    func givenDuplicateFailureWithFreshRetry_whenReported_thenRefreshesActionWithoutResettingPresentation(dismissed: Bool) {
        // given
        let state = IncidentPresentation()
        var oldCalls = 0
        var newCalls = 0
        let start = Date(timeIntervalSince1970: 0)
        state.report(source: "editor", message: "Read failed", retry: AlertAction(title: "Reload") { oldCalls += 1 })
        state.tick(now: start, paused: false)
        state.tick(now: start.addingTimeInterval(3), paused: false)
        if dismissed { state.dismiss() }
        // when
        let appeared = state.report(source: "editor", message: "Read failed", retry: AlertAction(title: "Reload") { newCalls += 1 })
        state.failures.first?.retry?.action()
        // then
        #expect(!appeared)
        #expect(state.remaining == 5)
        #expect(state.failures.count == 1)
        #expect(oldCalls == 0)
        #expect(newCalls == 1)
        if dismissed {
            #expect(state.current == nil)
        } else {
            #expect(state.current?.source == "editor")
            state.current?.retry?.action()
            #expect(newCalls == 2)
        }
    }

    @Test func givenAnotherCurrentFailure_whenOlderSourceRefreshesRetry_thenKeepsArrivalOrderAndCurrentNotification() {
        // given
        let state = IncidentPresentation()
        var retries = 0
        state.report(source: "editor", message: "Editor failed")
        state.report(source: "list", message: "List failed")
        // when
        state.report(source: "editor", message: "Editor failed", retry: AlertAction(title: "Reload") { retries += 1 })
        state.failures.first?.retry?.action()
        // then
        #expect(state.failures.map(\.source) == ["editor", "list"])
        #expect(state.current?.source == "list")
        #expect(retries == 1)
    }

    @Test(arguments: ["unknown", "resolved", "unrelated"])
    func givenSourceWithoutFailure_whenResolved_thenDoesNotNotifyPresentationObservers(scenario: String) {
        // given
        let state = IncidentPresentation()
        if scenario == "resolved" {
            state.report(source: "list", message: "List failed")
            state.resolve(source: "list")
        } else if scenario == "unrelated" {
            state.report(source: "detail", message: "Detail failed")
        }
        let before = state.failures
        let current = state.current
        let notifications = observe(state)
        // when
        state.resolve(source: "list")
        state.resolve(source: "list")
        // then
        #expect(notifications.current == 0)
        #expect(notifications.failures == 0)
        #expect(state.current == current)
        #expect(state.failures == before)
    }

    @Test(arguments: [false, true])
    func givenMatchingFailure_whenResolved_thenNotifiesRecoveryAndAllowsSameFailureToReappear(dismissed: Bool) {
        // given
        let state = IncidentPresentation()
        state.report(source: "list", message: "List failed")
        if dismissed { state.dismiss() }
        let notifications = observe(state)
        // when
        state.resolve(source: "list")
        // then
        #expect(notifications.failures == 1)
        #expect(notifications.current == (dismissed ? 0 : 1))
        #expect(state.current == nil)
        #expect(state.failures.isEmpty)
        #expect(state.report(source: "list", message: "List failed"))
        #expect(state.current?.source == "list")
        #expect(state.failures.count == 1)
    }

    private func observe(_ state: IncidentPresentation) -> IncidentObserverNotifications {
        let notifications = IncidentObserverNotifications()
        withObservationTracking { _ = state.current } onChange: {
            MainActor.assumeIsolated { notifications.current += 1 }
        }
        withObservationTracking { _ = state.failures } onChange: {
            MainActor.assumeIsolated { notifications.failures += 1 }
        }
        return notifications
    }

}

// MARK: - IncidentObserverNotifications

@MainActor private final class IncidentObserverNotifications {
    var current = 0
    var failures = 0
}
