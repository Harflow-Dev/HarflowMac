import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

private actor StatisticsPageScript {
    private var pages: [Result<StatisticsPage, ToolError>]
    private(set) var cursors: [String?] = []
    init(_ pages: [Result<StatisticsPage, ToolError>]) { self.pages = pages }
    func next(_ cursor: String?) -> Result<StatisticsPage, ToolError> {
        cursors.append(cursor)
        return pages.isEmpty ? .failure(.unreadable(tool: "ctl", exitCode: 0, stderr: "exhausted")) : pages.removeFirst()
    }

    func calls() -> [String?] { cursors }
}

private struct ScriptedStatisticsRepository: StatisticsRepository {
    let script: StatisticsPageScript
    func page(since _: String, before _: String, cursor: String?) async -> Result<StatisticsPage, ToolError> {
        await script.next(cursor)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant += duration } }
}

private struct SlowStatisticsRepository: StatisticsRepository {
    let clock: TestClock
    let answer: StatisticsPage
    func page(since _: String, before _: String, cursor _: String?) async -> Result<StatisticsPage, ToolError> {
        clock.advance(.seconds(2))
        return .success(answer)
    }
}

@MainActor
@Suite struct StatisticsHistoryWorkerTests {
    private func page(snapshot: String = "s", generation: String = "g", state: String = "ready", more: Bool = false) -> StatisticsPage {
        StatisticsPage(raw: [
            "projection_version": .number(1), "state": .string(state), "snapshot_id": .string(snapshot),
            "generation": .string(generation), "observed_at": .string("now"), "items": .array([]),
            "has_more": .bool(more), "next_cursor": more ? .string("next") : .null,
            "history_complete": .bool(true), "ownership_complete": .bool(true), "retained_history_only": .bool(true),
            "accounting_coverage": .object(["eligible_executions": .number(0), "available_executions": .number(0)]),
            "retention": .object(["state": .string("days"), "days": .number(90)])
        ])!
    }

    @Test func givenMultiplePages_whenRead_thenCursorAdvancesAndOnlyCompleteSnapshotReturns() async {
        // given
        let script = StatisticsPageScript([.success(page(more: true)), .success(page())])
        let repository = ScriptedStatisticsRepository(script: script)

        // when
        let result = await StatisticsHistoryWorker().read(repository: repository, since: "a", before: "b")

        // then
        guard case .ready(let snapshot) = result else { Issue.record("Expected complete snapshot"); return }
        #expect(snapshot.facts.isEmpty)
        #expect(await script.calls() == [nil, "next"])
    }

    @Test func givenSnapshotGenerationChangesAcrossPages_whenRead_thenPartialHistoryIsDiscarded() async {
        // given
        let script = StatisticsPageScript([.success(page(more: true)), .success(page(snapshot: "new")), .success(page(snapshot: "new"))])
        let repository = ScriptedStatisticsRepository(script: script)

        // when
        let result = await StatisticsHistoryWorker().read(repository: repository, since: "a", before: "b")

        // then
        guard case .ready = result else { Issue.record("Expired snapshot should restart from its first page"); return }
        #expect(await script.calls() == [nil, "next", nil])
    }

    @Test func givenUnsupportedOlderEngine_whenRead_thenUnsupportedIsPreserved() async {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "statistics-page", detail: "")
        let repository = ScriptedStatisticsRepository(script: StatisticsPageScript([.failure(error)]))

        // when
        let result = await StatisticsHistoryWorker().read(repository: repository, since: "a", before: "b")

        // then
        guard case .unsupported(let message) = result else { Issue.record("Expected explicit unsupported state"); return }
        #expect(message.contains("statistics-page"))
    }

    @Test func givenPageCompletesAfterDeadline_whenRead_thenNoReadySnapshotEscapes() async {
        // given
        let clock = TestClock()
        let repository = SlowStatisticsRepository(clock: clock, answer: page())

        // when
        let result = await StatisticsHistoryWorker(now: { clock.now() }, budget: .seconds(1))
            .read(repository: repository, since: "a", before: "b")

        // then
        guard case .failed(let message) = result else { Issue.record("An over-budget history page must be rejected"); return }
        #expect(message.contains("time budget"))
    }

    @Test func givenUnknownPageState_whenRead_thenItFailsClosedWithoutTotals() async {
        // given
        let repository = ScriptedStatisticsRepository(script: StatisticsPageScript([.success(page(state: "future-state"))]))

        // when
        let result = await StatisticsHistoryWorker().read(repository: repository, since: "a", before: "b")

        // then
        guard case .failed(let message) = result else { Issue.record("Unknown history state must not become ready"); return }
        #expect(message.contains("incomplete or unavailable"))
    }
}
