import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - PendingLaunchInventoryTests

@Suite struct PendingLaunchInventoryTests {
    private func read(_ pages: [[String: JSONValue]]) async -> PendingLaunchInventoryReader.Read {
        let runner = PendingLaunchRunner(pages: pages.map { pendingEnvelope($0) })
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        return await PendingLaunchInventoryReader(now: { .now }).read(client: client)
    }

    @Test func givenIntermediateUnknownCoverage_whenAllCursorsFinishComplete_thenTraversalCompletes() async {
        // given / when
        let result = await read([pendingPage(["one"], cursor: "cursor"), pendingPage(["two"])])
        // then
        #expect(result.complete)
        #expect(result.rows.map(\.taskID) == ["one", "two"])
    }

    @Test func givenEmptyFilteredPageWithProgress_whenCursorAdvances_thenItIsValid() async {
        // given / when
        let result = await read([pendingPage(cursor: "cursor"), pendingPage(["two"])])
        // then
        #expect(result.complete && result.rows.count == 1)
    }

    @Test func givenRepeatedCursor_whenTraversed_thenCycleIsIncomplete() async {
        // given / when
        let result = await read([pendingPage(["one"], cursor: "cursor"), pendingPage(["two"], cursor: "cursor")])
        // then
        #expect(result.failure == .malformed && !result.complete)
    }

    @Test func givenDuplicateFullIDAcrossPages_whenTraversed_thenNoFalseCompleteCheck() async {
        // given / when
        let result = await read([pendingPage(["one"], cursor: "cursor"), pendingPage(["one"])])
        // then
        #expect(result.failure == .malformed && !result.complete)
    }

    @Test func givenNamespaceRevisionChange_whenTraversed_thenRowsDoNotBecomeComplete() async {
        // given / when
        let result = await read([pendingPage(["one"], cursor: "cursor"), pendingPage(["two"], revision: String(repeating: "c", count: 64))])
        // then
        #expect(result.failure == .malformed)
    }

    @Test func givenFutureRowAlongsideHealthyNeighbor_whenProducerSaysComplete_thenClientComprehensionStaysIncomplete() async {
        // given
        let items = [pendingItem("healthy"), pendingItem("future", state: "future_state")]
        // when
        let result = await read([pendingPage(overrides: ["items": .array(items.map(JSONValue.object)), "examined_count": .number(2)])])
        // then
        #expect(result.rows.count == 2 && result.rows[0].launch != nil)
        #expect(!result.complete && result.failure == .incomplete)
    }

    @Test func givenCursorExpiry_whenRestartCompletes_thenRestartUsesSharedBudget() async {
        // given
        let runner = PendingLaunchRunner(pages: [pendingEnvelope(pendingPage(["old"], cursor: "cursor")),
                                                 pendingEnvelope([:], error: "pending_cursor_expired"),
                                                 pendingEnvelope(pendingPage(["new"]))])
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await PendingLaunchInventoryReader(now: { .now }).read(client: client)
        // then
        #expect(result.complete && result.rows.map(\.taskID) == ["new"])
        #expect(await runner.calls.filter { $0.first == "task-pending-page" }.count == 3)
    }

    @Test func givenTwoCursorExpiries_whenTraversed_thenOnlyOneRestartOccurs() async {
        // given
        let runner = PendingLaunchRunner(pages: [pendingEnvelope(pendingPage(cursor: "one")), pendingEnvelope([:], error: "pending_cursor_expired"),
                                                 pendingEnvelope(pendingPage(cursor: "two")), pendingEnvelope([:], error: "pending_cursor_expired")])
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await PendingLaunchInventoryReader(now: { .now }).read(client: client)
        // then
        #expect(!result.complete)
        #expect(await runner.calls.filter { $0.first == "task-pending-page" }.count == 4)
    }

    @Test func givenSixtyFiveProgressingPages_whenTraversed_thenSixtyFourRequestAndEightMiBBoundIsGlobal() async {
        // given
        let pages = (0 ..< 65).map { pendingEnvelope(pendingPage(cursor: "cursor\($0)")) }
        let runner = PendingLaunchRunner(pages: pages)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await PendingLaunchInventoryReader(now: { .now }).read(client: client)
        // then
        #expect(result.failure == .requestBudget)
        #expect(await runner.calls.filter { $0.first == "task-pending-page" }.count == 64)
    }

    @Test func givenDeadlineAdvancesAfterResponse_whenTraversed_thenFinalCompleteDoesNotEscapeDeadline() async {
        // given
        let clock = LockedBox(ContinuousClock.now)
        let first = LockedBox(true)
        let runner = PendingLaunchRunner()
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let reader = PendingLaunchInventoryReader(now: {
            if first.value { first.mutate { $0 = false }; return clock.value }
            clock.mutate { $0 = $0.advanced(by: .seconds(61)) }
            return clock.value
        })
        // when
        let result = await reader.read(client: client)
        // then
        #expect(result.failure == .deadline)
    }
}
