@testable import HfRepository
import MonitorCore
import Testing

// MARK: - PublicEventSummaryCallIdentityTests

@Suite struct PublicEventSummaryCallIdentityTests {
    @Test func givenPendingEdit_whenShellReusesCallID_thenShellResultCannotFalselyConfirmEditedFile() {
        // given
        var sut = PublicEventSummaryReducer()
        let shell = ObservationFixtures.record(2, "tool_call", ["call_id": .string("shared"), "tool": .string("shell"),
            "category": .string("shell"), "input_preview": .string("command"), "command": .string("true")])
        // when
        sut.fold(ObservationFixtures.page([ObservationFixtures.call(1, id: "shared", path: "a"), shell,
            ObservationFixtures.result(3, id: "shared", ok: true)]))
        // then
        #expect(sut.snapshot(caughtUp: true).state == .unavailable)
        #expect(sut.snapshot(caughtUp: true).issues.contains(.ambiguousCall))
        #expect(sut.snapshot(caughtUp: true).files.isEmpty)
        #expect(sut.snapshot(caughtUp: true).counts == nil)
    }

    @Test func givenPendingShellCalls_whenDistinctUnresolvedIDsExceedCap_thenProjectionIsLimited() {
        // given
        var limits = PublicEventSummaryLimits()
        limits.pendingCalls = 1
        var sut = PublicEventSummaryReducer(limits: limits)
        let calls = ["one", "two"].enumerated().map { index, id in
            ObservationFixtures.record(index + 1, "tool_call", ["call_id": .string(id), "tool": .string("shell"),
                "category": .string("shell"), "input_preview": .string("command")])
        }
        // when
        sut.fold(ObservationFixtures.page(calls))
        // then
        #expect(sut.snapshot(caughtUp: true).state == .limited)
        #expect(sut.snapshot(caughtUp: true).counts == nil)
    }
}
