import Foundation
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

}
