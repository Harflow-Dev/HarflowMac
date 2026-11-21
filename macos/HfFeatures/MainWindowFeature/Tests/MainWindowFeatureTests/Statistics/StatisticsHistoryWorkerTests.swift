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
    private func page(
        snapshot: String = "s",
        generation: String = "g",
        state: String = "ready",
        more: Bool = false,
        facts: [StatisticsFact] = [],
        costQualified: Bool = false,
        costCoverage: StatisticsCostCoverage? = nil,
        malformedCostCoverage: Bool = false
    ) -> StatisticsPage {
        var raw: [String: JSONValue] = [
            "projection_version": .number(1), "state": .string(state), "snapshot_id": .string(snapshot),
            "generation": .string(generation), "observed_at": .string("now"),
            "items": .array(facts.map { .object($0.raw) }),
            "has_more": .bool(more), "next_cursor": more ? .string("next") : .null,
            "history_complete": .bool(true), "ownership_complete": .bool(true), "retained_history_only": .bool(true),
            "accounting_coverage": .object(["eligible_executions": .number(0), "available_executions": .number(0)]),
            "retention": .object(["state": .string("days"), "days": .number(90)])
        ]
        if let costCoverage {
            raw["cost_coverage"] = .object([
                "eligible_executions": .number(Double(costCoverage.eligibleExecutions)),
                "available_executions": .number(Double(costCoverage.availableExecutions))
            ])
        } else if malformedCostCoverage {
            raw["cost_coverage"] = .object([
                "eligible_executions": .number(1), "available_executions": .number(2)
            ])
        }
        return StatisticsPage(raw: raw, costQualified: costQualified)!
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

    @Test func givenQualifiedCostCoverageAcrossPages_whenRead_thenCountsReconcileAfterCompleteWalk() async {
        // given
        let coverage = StatisticsCostCoverage(eligibleExecutions: 2, availableExecutions: 1)
        let reported = costFact("reported", kind: "initial", cost: 2.5)
        let unavailable = costFact("unavailable", kind: "resume", cost: nil)
        let native = costFact("native", kind: "native", cost: nil)
        let script = StatisticsPageScript([
            .success(page(more: true, facts: [reported, native], costQualified: true, costCoverage: coverage)),
            .success(page(facts: [unavailable], costQualified: true, costCoverage: coverage))
        ])

        // when
        let result = await StatisticsHistoryWorker().read(repository: ScriptedStatisticsRepository(script: script), since: "a", before: "b")

        // then
        guard case .ready(let snapshot) = result else { Issue.record("Complete history should remain ready"); return }
        #expect(snapshot.facts.count == 3)
        #expect(snapshot.costCoverage == coverage)
        #expect(await script.calls() == [nil, "next"])
    }

    @Test func givenPageCoverageRepeatsButDisagreesWithAccumulatedFacts_whenRead_thenHistoryStaysReadyWithoutCost() async {
        // given
        let firstCoverage = StatisticsCostCoverage(eligibleExecutions: 2, availableExecutions: 1)
        let secondCoverage = firstCoverage
        let first = costFact("reported", kind: "initial", cost: 2)
        let second = costFact("also-reported", kind: "resume", cost: 3)
        let script = StatisticsPageScript([
            .success(page(more: true, facts: [first], costQualified: true, costCoverage: firstCoverage)),
            .success(page(facts: [second], costQualified: true, costCoverage: secondCoverage))
        ])

        // when
        let result = await StatisticsHistoryWorker().read(repository: ScriptedStatisticsRepository(script: script), since: "a", before: "b")

        // then
        guard case .ready(let snapshot) = result else { Issue.record("Cost inconsistency must not fail time and usage history"); return }
        #expect(snapshot.costCoverage == nil)
        #expect(snapshot.facts.count == 2)
    }

    @Test func givenCoverageCountsDifferAcrossPages_whenRead_thenHistoryStaysReadyWithoutCost() async {
        // given
        let actualCoverage = StatisticsCostCoverage(eligibleExecutions: 2, availableExecutions: 1)
        let differentCoverage = StatisticsCostCoverage(eligibleExecutions: 2, availableExecutions: 2)
        let first = costFact("reported", kind: "initial", cost: 2)
        let second = costFact("silent", kind: "resume", cost: nil)
        let script = StatisticsPageScript([
            .success(page(more: true, facts: [first], costQualified: true, costCoverage: actualCoverage)),
            .success(page(facts: [second], costQualified: true, costCoverage: differentCoverage))
        ])

        // when
        let result = await StatisticsHistoryWorker().read(
            repository: ScriptedStatisticsRepository(script: script), since: "a", before: "b"
        )

        // then
        guard case .ready(let snapshot) = result else { Issue.record("Changing cost counts must not fail history"); return }
        #expect(snapshot.costCoverage == nil)
        #expect(snapshot.facts.count == 2)
    }

    @Test func givenCostCapabilityChangesBetweenPages_whenRead_thenHistoryRemainsReadyWithoutCost() async {
        // given
        let coverage = StatisticsCostCoverage(eligibleExecutions: 1, availableExecutions: 1)
        let execution = costFact("one", kind: "initial", cost: 2)
        let script = StatisticsPageScript([
            .success(page(more: true, facts: [execution], costQualified: true, costCoverage: coverage)),
            .success(page(facts: [], costQualified: false))
        ])

        // when
        let result = await StatisticsHistoryWorker().read(repository: ScriptedStatisticsRepository(script: script), since: "a", before: "b")

        // then
        guard case .ready(let snapshot) = result else { Issue.record("Capability change should suppress cost only"); return }
        #expect(snapshot.costCoverage == nil)
    }

    @Test func givenInvalidCostFactOrCoverage_whenRead_thenHistoryRemainsReadyWithoutCounts() async {
        // given
        let coverage = StatisticsCostCoverage(eligibleExecutions: 1, availableExecutions: 1)
        let invalid = costFact("unknown-kind", kind: "future", cost: 3)
        let script = StatisticsPageScript([
            .success(page(facts: [invalid], costQualified: true, costCoverage: coverage))
        ])

        // when
        let result = await StatisticsHistoryWorker().read(repository: ScriptedStatisticsRepository(script: script), since: "a", before: "b")
        let malformedPage = page(costQualified: true, malformedCostCoverage: true)
        let malformedResult = await StatisticsHistoryWorker().read(
            repository: ScriptedStatisticsRepository(script: StatisticsPageScript([.success(malformedPage)])),
            since: "a", before: "b"
        )

        // then
        guard case .ready(let snapshot) = result, case .ready(let malformedSnapshot) = malformedResult else {
            Issue.record("Invalid cost data must not discard otherwise complete history")
            return
        }
        #expect(snapshot.costCoverage == nil)
        #expect(malformedSnapshot.costCoverage == nil)
    }

    @Test func givenNoEligibleExecutionFacts_whenRead_thenQualifiedZeroCoverageIsRetained() async {
        // given
        let workflow = StatisticsFact(raw: [
            "id": .string("workflow"), "kind": .string("workflow"), "status": .string("completed"),
            "started_at": .number(10), "finished_at": .number(20), "cohort_started_at": .number(10)
        ], costQualified: true)
        let coverage = StatisticsCostCoverage(eligibleExecutions: 0, availableExecutions: 0)
        let repository = ScriptedStatisticsRepository(script: StatisticsPageScript([
            .success(page(facts: [workflow], costQualified: true, costCoverage: coverage))
        ]))

        // when
        let result = await StatisticsHistoryWorker().read(repository: repository, since: "a", before: "b")

        // then
        guard case .ready(let snapshot) = result else { Issue.record("Qualified zero-eligible history should stay ready"); return }
        #expect(snapshot.costCoverage == coverage)
    }

    @Test func givenDuplicateExecutionIdentityAcrossPages_whenRead_thenExistingHistoryRefusalStillApplies() async {
        // given
        let coverage = StatisticsCostCoverage(eligibleExecutions: 2, availableExecutions: 2)
        let first = costFact("duplicate", kind: "initial", cost: 2)
        let second = costFact("duplicate", kind: "resume", cost: 3)
        let repository = ScriptedStatisticsRepository(script: StatisticsPageScript([
            .success(page(more: true, facts: [first], costQualified: true, costCoverage: coverage)),
            .success(page(facts: [second], costQualified: true, costCoverage: coverage))
        ]))

        // when
        let result = await StatisticsHistoryWorker().read(repository: repository, since: "a", before: "b")

        // then
        guard case .failed(let message) = result else { Issue.record("Duplicate execution identities must not produce totals"); return }
        #expect(message.contains("duplicate facts"))
    }

    private func costFact(_ id: String, kind: String, cost: Double?) -> StatisticsFact {
        let hasCost = cost != nil
        return StatisticsFact(raw: [
            "id": .string(id), "kind": .string("execution"), "status": .string("completed"),
            "started_at": .number(10), "finished_at": .number(20), "cohort_started_at": .number(10),
            "duration_additive": .bool(true), "usage_additive": .bool(false),
            "execution_kind": .string(kind),
            "task_id": .string(id), "cost_usd": cost.map { .number($0) } ?? .null,
            "cost_provenance": hasCost ? .string("backend_reported") : .null,
            "cost_additive": .bool(hasCost)
        ], costQualified: true)
    }
}
