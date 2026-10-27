import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

private final class CountingStatisticsRepository: StatisticsRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func page(since _: String, before _: String, cursor _: String?) async -> Result<StatisticsPage, ToolError> {
        lock.withLock { count += 1 }
        let page = StatisticsPage(raw: [
            "projection_version": .number(1), "state": .string("ready"), "snapshot_id": .string("snapshot"),
            "generation": .string("generation"), "observed_at": .string("now"), "items": .array([]),
            "has_more": .bool(false), "history_complete": .bool(true), "ownership_complete": .bool(true),
            "retained_history_only": .bool(true),
            "accounting_coverage": .object(["eligible_executions": .number(0), "available_executions": .number(0)]),
            "retention": .object(["state": .string("days"), "days": .number(90)])
        ])!
        return .success(page)
    }
}

private final class StatisticsRefreshGate: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func markStarted() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            started = true
            defer { startWaiter = nil }
            return startWaiter
        }
        waiter?.resume()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            let alreadyStarted = lock.withLock {
                if started { return true }
                startWaiter = continuation
                return false
            }
            if alreadyStarted { continuation.resume() }
        }
    }

    func waitForRelease() async {
        await withCheckedContinuation { continuation in
            let alreadyReleased = lock.withLock {
                if released { return true }
                releaseWaiter = continuation
                return false
            }
            if alreadyReleased { continuation.resume() }
        }
    }

    func release() {
        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            released = true
            defer { releaseWaiter = nil }
            return releaseWaiter
        }
        waiter?.resume()
    }
}

private final class SequencedStatisticsRepository: StatisticsRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [Result<StatisticsPage, ToolError>]
    private let refreshGate: StatisticsRefreshGate?
    private var count = 0
    var calls: Int { lock.withLock { count } }

    init(_ results: [Result<StatisticsPage, ToolError>], refreshGate: StatisticsRefreshGate? = nil) {
        self.results = results
        self.refreshGate = refreshGate
    }

    func page(since _: String, before _: String, cursor _: String?) async -> Result<StatisticsPage, ToolError> {
        let (call, result) = lock.withLock { () -> (Int, Result<StatisticsPage, ToolError>) in
            count += 1
            return (
                count,
                results.isEmpty ? .failure(.unreadable(tool: "ctl", exitCode: 1, stderr: "exhausted")) : results.removeFirst()
            )
        }
        if call == 2, let refreshGate { refreshGate.markStarted(); await refreshGate.waitForRelease() }
        return result
    }
}

@MainActor
private struct FixedStatisticsUseCase: StatisticsUseCase {
    let repository: any StatisticsRepository
}

@MainActor
@Suite struct StatisticsVMTests {
    @Test func givenEmptyHistory_whenRangeControlSelectsSevenDays_thenVMReloadsAndRetainsSelection() async {
        // given
        let repository = CountingStatisticsRepository()
        let vm = StatisticsVM(useCase: FixedStatisticsUseCase(repository: repository), now: { Date(timeIntervalSince1970: 1_800_000_000) })

        // when
        vm.didAppear()
        await waitUntil(timeout: 5) { vm.presentation.state == .empty("No finished work in this retained history.") }

        // then
        #expect(repository.calls == 1)
        vm.selectRange(.seven)
        await waitUntil(timeout: 5) { vm.presentation.state == .empty("No finished work in this retained history.") && vm.presentation.range == .seven }
        #expect(repository.calls == 2)
        vm.didDisappear()
        vm.didDisappear()
        #expect(repository.calls == 2)
    }

    @Test func givenUnavailableRepository_whenMounted_thenScreenShowsUnsupportedInsteadOfEmpty() async {
        // given
        struct UnsupportedRepository: StatisticsRepository {
            func page(since _: String, before _: String, cursor _: String?) async -> Result<StatisticsPage, ToolError> {
                .failure(.unsupportedCommand(tool: "harflow-ctl", command: "statistics-page", detail: ""))
            }
        }
        let vm = StatisticsVM(useCase: FixedStatisticsUseCase(repository: UnsupportedRepository()))

        // when
        vm.didAppear()
        await waitUntil(timeout: 5) {
            if case .unsupported = vm.presentation.state { return true }
            return false
        }

        // then
        if case .unsupported(let message) = vm.presentation.state {
            #expect(message.contains("statistics-page"))
        } else {
            Issue.record("Expected unsupported Statistics state")
        }
        vm.didDisappear()
    }

    @Test func givenGoodSnapshot_whenRefreshFails_thenLastGoodPresentationAndNoticeSurviveFiltering() async {
        // given
        let goodPage = StatisticsPage(raw: [
            "projection_version": .number(1), "state": .string("ready"), "snapshot_id": .string("snapshot"),
            "generation": .string("generation"), "observed_at": .string("now"),
            "items": .array([.object([
                "id": .string("execution"), "kind": .string("execution"), "status": .string("completed"),
                "started_at": .number(1_800_000_000), "finished_at": .number(1_800_000_060),
                "cohort_started_at": .number(1_800_000_000), "execution_seconds": .number(60),
                "duration_additive": .bool(true), "usage_additive": .bool(false), "repo_path": .string("/repo")
            ])]),
            "has_more": .bool(false), "history_complete": .bool(true), "ownership_complete": .bool(true),
            "retained_history_only": .bool(true),
            "accounting_coverage": .object(["eligible_executions": .number(1), "available_executions": .number(0)]),
            "retention": .object(["state": .string("days"), "days": .number(90)])
        ])!
        let gate = StatisticsRefreshGate()
        let repository = SequencedStatisticsRepository(
            [.success(goodPage), .failure(.unreadable(tool: "ctl", exitCode: 1, stderr: "refresh failed"))],
            refreshGate: gate
        )
        let vm = StatisticsVM(
            useCase: FixedStatisticsUseCase(repository: repository),
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        // when
        vm.didAppear()
        await waitUntil(timeout: 5) { vm.presentation.state == .ready }
        let goodChartTotal = vm.presentation.chart.total
        vm.retry()
        await gate.waitUntilStarted()
        vm.selectMeasure(.usage)
        gate.release()
        await waitUntil(timeout: 5) { vm.presentation.refreshFailure != nil }

        // then
        #expect(repository.calls == 2)
        #expect(vm.presentation.state == .ready)
        #expect(goodChartTotal == "1.0 min")
        #expect(vm.presentation.chart.title == "Usage")
        #expect(vm.presentation.chart.total == "Unavailable")
        #expect(vm.presentation.coverage.contains { $0.contains("0 of 1 independent executions") })
        #expect(vm.presentation.refreshFailure?.contains("refresh failed") == true)
        await waitUntil(timeout: 5) { vm.presentation.measure == .usage }
        #expect(vm.presentation.state == .ready)
        #expect(vm.presentation.refreshFailure?.contains("refresh failed") == true)
        vm.didDisappear()
    }

}
