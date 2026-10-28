import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - StartScreenVMLifecycleTests

final class StartScreenTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    private var storedUptime: TimeInterval = 1_000

    init(_ date: Date) { self.stored = date }
    func read() -> Date { lock.withLock { stored } }
    func advance(_ interval: TimeInterval) { lock.withLock { stored.addTimeInterval(interval) } }
    func readUptime() -> TimeInterval { lock.withLock { storedUptime } }
    func advanceUptime(_ interval: TimeInterval) { lock.withLock { storedUptime += interval } }
}

actor StartScreenPageGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var hasBlocked = false
    private var released = false
    private var observers: [CheckedContinuation<Void, Never>] = []

    func block() async {
        hasBlocked = true
        if released { return }
        for observer in observers { observer.resume() }
        observers.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilBlocked() async {
        if hasBlocked { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private final class StartScreenStateChangeCount: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.withLock { stored += 1 } }
    var value: Int { lock.withLock { stored } }
}

actor StartScreenProbeSource: StartScreenHistorySource {
    private var taskReadCount = 0
    private var workflowReadCount = 0
    private var definitionReadCount = 0
    private var completedTaskReads = 0
    private var completedWorkflowReads = 0
    private var completedDefinitionReads = 0
    private let taskGate: StartScreenPageGate?
    private let workflowGate: StartScreenPageGate?
    private let definitionsGate: StartScreenPageGate?
    private var savedDefinitions: [WorkflowRecord]
    private var savedRuns: [[String: JSONValue]]
    private var definitionsMode: DefinitionMode = .ready
    private var nextTaskGate: StartScreenPageGate?
    private var nextWorkflowGate: StartScreenPageGate?

    init(gate: StartScreenPageGate? = nil, workflowGate: StartScreenPageGate? = nil,
         definitionsGate: StartScreenPageGate? = nil, definitions: [WorkflowRecord] = [], runs: [[String: JSONValue]] = []) {
        self.taskGate = gate
        self.workflowGate = workflowGate
        self.definitionsGate = definitionsGate
        self.savedDefinitions = definitions
        self.savedRuns = runs
    }

    func taskPage(cursor: String?) async throws -> TaskHistoryPage {
        taskReadCount += 1
        resumeReadStartWaiters()
        let gate = cursor == nil ? nextTaskGate ?? taskGate : nil
        if cursor == nil, nextTaskGate != nil { nextTaskGate = nil }
        await gate?.block()
        completedTaskReads += 1
        resumeScanWaiters()
        for waiter in completionWaiters { waiter.resume() }
        completionWaiters.removeAll()
        return TaskHistoryPage(raw: Self.page(items: []))!
    }

    func workflowPage(cursor: String?) async throws -> HistoryPage {
        workflowReadCount += 1
        resumeReadStartWaiters()
        let gate = cursor == nil ? nextWorkflowGate ?? workflowGate : nil
        if cursor == nil, nextWorkflowGate != nil { nextWorkflowGate = nil }
        await gate?.block()
        completedWorkflowReads += 1
        resumeScanWaiters()
        return HistoryPage(raw: Self.page(items: savedRuns))!
    }

    func definitions() async throws -> [WorkflowRecord] {
        definitionReadCount += 1
        resumeReadStartWaiters()
        if definitionsGate != nil { await definitionsGate?.block() }
        completedDefinitionReads += 1
        resumeScanWaiters()
        for waiter in definitionWaiters { waiter.resume() }
        definitionWaiters.removeAll()
        for (expected, waiter) in definitionCountWaiters where completedDefinitionReads >= expected { waiter.resume() }
        definitionCountWaiters.removeAll { completedDefinitionReads >= $0.0 }
        if definitionsMode == .preparing { throw StartScreenHistoryScanner.ScanError.preparing }
        if definitionsMode == .failed { throw ProbeError.definitionsFailed }
        return savedDefinitions
    }

    func setDefinitions(_ definitions: [WorkflowRecord]) { savedDefinitions = definitions }
    func setRuns(_ runs: [[String: JSONValue]]) { savedRuns = runs }
    func setDefinitionsMode(_ mode: DefinitionMode) { definitionsMode = mode }
    func blockNextHistoryScan() -> (StartScreenPageGate, StartScreenPageGate) {
        let task = StartScreenPageGate(), workflow = StartScreenPageGate()
        nextTaskGate = task
        nextWorkflowGate = workflow
        return (task, workflow)
    }

    func waitForScanReads(_ expected: Int) async {
        if completedTaskReads >= expected, completedWorkflowReads >= expected, completedDefinitionReads >= expected { return }
        await withCheckedContinuation { scanWaiters.append((expected, $0)) }
    }

    func counts() -> (Int, Int, Int) { (taskReadCount, workflowReadCount, definitionReadCount) }
    func waitForReadCounts(_ expected: Int) async {
        if taskReadCount >= expected, workflowReadCount >= expected, definitionReadCount >= expected { return }
        await withCheckedContinuation { readStartWaiters.append($0) }
    }

    func waitForTaskReadCompletion() async {
        if completedTaskReads > 0 { return }
        await withCheckedContinuation { continuation in
            // The test releases the gate only after registering this waiter.
            completionWaiters.append(continuation)
        }
    }

    func waitForDefinitionReadCompletion() async {
        if completedDefinitionReads > 0 { return }
        await withCheckedContinuation { continuation in definitionWaiters.append(continuation) }
    }

    func waitForDefinitionReadCount(_ expected: Int) async {
        if completedDefinitionReads >= expected { return }
        await withCheckedContinuation { continuation in definitionCountWaiters.append((expected, continuation)) }
    }

    private var completionWaiters: [CheckedContinuation<Void, Never>] = []
    private var definitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var definitionCountWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var scanWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var readStartWaiters: [CheckedContinuation<Void, Never>] = []

    private func resumeReadStartWaiters() {
        guard taskReadCount > 0, workflowReadCount > 0, definitionReadCount > 0 else { return }
        for waiter in readStartWaiters { waiter.resume() }
        readStartWaiters.removeAll()
    }

    private func resumeScanWaiters() {
        for (expected, waiter) in scanWaiters
            where completedTaskReads >= expected && completedWorkflowReads >= expected && completedDefinitionReads >= expected {
            waiter.resume()
        }
        scanWaiters.removeAll {
            completedTaskReads >= $0.0 && completedWorkflowReads >= $0.0 && completedDefinitionReads >= $0.0
        }
    }

    enum DefinitionMode: Equatable, Sendable { case ready, preparing, failed }
    private enum ProbeError: Error { case definitionsFailed }

    private static func page(items: [[String: JSONValue]]) -> [String: JSONValue] {
        ["items": .array(items.map(JSONValue.object)), "has_more": .bool(false), "next_cursor": .null,
         "bootstrap_pending": .bool(false), "history_incomplete": .bool(false), "authority_incomplete": .bool(false),
         "counts_complete": .bool(true), "total_active_count": .number(0),
         "catalog_state": .object(["status": .string("ready")])]
    }
}

@MainActor
@Suite struct StartScreenVMLifecycleTests {
    struct Fixture {
        var sut: StartScreenVM
        var source: StartScreenProbeSource
        var routing: MockStartScreenRouting
        var changes: PassthroughSubject<[TaskInfo], Never>
        var history: CurrentValueSubject<HistoryLoadingState, Never>
        var clock: StartScreenTestClock
    }

    func makeSUT(
        start: Date = Date(timeIntervalSince1970: 1_790_000_000),
        gate: StartScreenPageGate? = nil, workflowGate: StartScreenPageGate? = nil,
        definitionsGate: StartScreenPageGate? = nil, definitions: [WorkflowRecord] = [],
        runs: [[String: JSONValue]] = [],
        refreshInterval: TimeInterval = 86_400
    ) -> Fixture {
        let source = StartScreenProbeSource(gate: gate, workflowGate: workflowGate,
                                            definitionsGate: definitionsGate, definitions: definitions, runs: runs)
        let useCase = MockStartScreenUseCase()
        let routing = MockStartScreenRouting()
        let changes = PassthroughSubject<[TaskInfo], Never>()
        let history = CurrentValueSubject<HistoryLoadingState, Never>(HistoryLoadingState())
        let clock = StartScreenTestClock(start)
        given(useCase).source.willReturn(source)
        given(useCase).changes().willReturn(changes.eraseToAnyPublisher())
        given(useCase).errors().willReturn(Just(nil).eraseToAnyPublisher())
        given(useCase).historyState().willReturn(StartScreenViewRepository.semanticHistoryState(history.eraseToAnyPublisher()))
        let sut = StartScreenVM(useCase: useCase, routing: routing, now: { clock.read() }, uptime: { clock.readUptime() }, calendar: {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar
        }, refreshInterval: refreshInterval, tickInterval: .seconds(3_600))
        return Fixture(sut: sut, source: source, routing: routing, changes: changes, history: history, clock: clock)
    }

    private func task(_ id: String, status: String) -> TaskInfo {
        TaskInfo(.object(["task_id": .string(id), "status": .string(status), "workflow_run_id": .null]))!
    }

    private func definition(_ name: String, workflowID: String) -> WorkflowRecord {
        WorkflowRecord(raw: ["name": .string(name), "workflow_id": .string(workflowID)])
    }

    @Test func givenHistoryReadinessChangesWithoutTaskChanges_whenPublished_thenMetricsClearAndChoicesRemain() async {
        // given
        let fixture = makeSUT(definitions: [definition("Alpha", workflowID: "alpha"), definition("Zulu", workflowID: "zulu")])
        fixture.sut.didAppear()
        await waitUntil { !fixture.sut.loading }
        #expect(fixture.sut.presentation.status == "Nothing running.")
        #expect(fixture.sut.presentation.rows.map(\.count) == ["Never run", "Never run"])

        // when
        var changedReadiness = fixture.history.value
        changedReadiness.historyIncomplete = true
        changedReadiness.countsComplete = false
        fixture.history.send(changedReadiness)
        await waitUntil { fixture.sut.presentation.status == nil && fixture.sut.presentation.rows.allSatisfy { $0.count == nil } }

        // then
        #expect(fixture.sut.loading)
        #expect(fixture.sut.definitionsAvailable)
        #expect(fixture.sut.presentation.rows.map(\.name) == ["Alpha", "Zulu"])
        fixture.sut.didDisappear()
    }

    @Test func givenDefinitionsArriveBeforeBlockedHistories_whenReadinessChanges_thenAlphabeticalChoicesRemainAvailable() async {
        // given
        let fixture = makeSUT(
                              definitions: [definition("Zebra", workflowID: "z"), definition("Alpha", workflowID: "a")],
                              refreshInterval: 30)
        var initialReadiness = fixture.history.value
        initialReadiness.countsComplete = true
        fixture.history.send(initialReadiness)
        fixture.sut.didAppear()
        await waitUntil { !fixture.sut.loading }
        #expect(fixture.sut.presentation.status == "Nothing running.")
        #expect(fixture.sut.presentation.rows.map(\.name) == ["Alpha", "Zebra"])
        #expect(fixture.sut.presentation.rows.allSatisfy { $0.count == "Never run" })
        let (taskGate, workflowGate) = await fixture.source.blockNextHistoryScan()
        fixture.clock.advanceUptime(30)
        await fixture.sut.tick()
        await taskGate.waitUntilBlocked()
        await workflowGate.waitUntilBlocked()
        await fixture.source.waitForDefinitionReadCount(2)

        // when
        var changedReadiness = initialReadiness
        changedReadiness.historyIncomplete = true
        changedReadiness.countsComplete = false
        fixture.history.send(changedReadiness)
        await waitUntil {
            fixture.sut.loading && fixture.sut.presentation.status == nil
                && fixture.sut.presentation.rows.allSatisfy { $0.count == nil }
        }

        // then
        #expect(fixture.sut.presentation.rows.map(\.name) == ["Alpha", "Zebra"])
        #expect(fixture.sut.presentation.rows.allSatisfy { $0.count == nil })
        let publications = StartScreenStateChangeCount()
        withObservationTracking { _ = fixture.sut.state } onChange: { publications.increment() }
        await taskGate.release()
        await workflowGate.release()
        await fixture.source.waitForScanReads(2)

        // The stale scan is rejected. Only the next eligible monotonic refresh may restore metrics.
        fixture.clock.advanceUptime(29)
        await fixture.sut.tick()
        let beforeDeadline = await fixture.source.counts()
        #expect(beforeDeadline.0 == 2)
        let (replacementTaskGate, replacementWorkflowGate) = await fixture.source.blockNextHistoryScan()
        fixture.clock.advanceUptime(1)
        await fixture.sut.tick()
        await replacementTaskGate.waitUntilBlocked()
        await replacementWorkflowGate.waitUntilBlocked()
        await fixture.source.waitForReadCounts(3)

        // Starting the replacement proves the stale scan released its single-flight slot.
        #expect(fixture.sut.loading)
        #expect(fixture.sut.presentation.status == nil)
        #expect(fixture.sut.presentation.rows.map(\.name) == ["Alpha", "Zebra"])
        #expect(fixture.sut.presentation.rows.allSatisfy { $0.count == nil })
        #expect(publications.value == 0)
        await replacementTaskGate.release()
        await replacementWorkflowGate.release()
        await fixture.source.waitForScanReads(3)
        await waitUntil { !fixture.sut.loading }
        #expect(publications.value == 1)
        #expect(fixture.sut.state.presentation.status == "Nothing running.")
        fixture.sut.didDisappear()
    }

    @Test func givenHistoriesAreBlocked_whenTheyComplete_thenLoadingAndMetricsPublishAsOneState() async {
        // given
        let taskGate = StartScreenPageGate()
        let workflowGate = StartScreenPageGate()
        let fixture = makeSUT(gate: taskGate, workflowGate: workflowGate,
                              definitions: [definition("Alpha", workflowID: "alpha")])
        fixture.sut.didAppear()
        await taskGate.waitUntilBlocked()
        await workflowGate.waitUntilBlocked()
        await waitUntil { fixture.sut.definitionsAvailable }
        #expect(fixture.sut.loading)
        #expect(fixture.sut.presentation.rows == [StartScreenRow(id: "Alpha", name: "Alpha", count: nil)])
        let publications = StartScreenStateChangeCount()
        withObservationTracking { _ = fixture.sut.state } onChange: { publications.increment() }

        // when
        await taskGate.release()
        await workflowGate.release()
        await waitUntil { !fixture.sut.loading }

        // then
        #expect(publications.value == 1)
        #expect(fixture.sut.state.loading == false)
        #expect(fixture.sut.state.definitionsAvailable)
        #expect(fixture.sut.state.presentation.status == "Nothing running.")
        #expect(fixture.sut.state.presentation.rows == [StartScreenRow(id: "Alpha", name: "Alpha", count: "Never run")])
        fixture.sut.didDisappear()
    }

    @Test func givenAnUnchangedDefinitionPollWhileHistoryIsPending_whenResultsArrive_thenItDoesNotPublishFallbackMetrics() async {
        // given
        let fixture = makeSUT(definitions: [definition("Alpha", workflowID: "alpha")], refreshInterval: 30)
        fixture.sut.didAppear()
        await waitUntil { !fixture.sut.loading }
        let completeState = fixture.sut.state
        let publications = StartScreenStateChangeCount()
        withObservationTracking { _ = fixture.sut.state } onChange: { publications.increment() }
        let (taskGate, workflowGate) = await fixture.source.blockNextHistoryScan()
        fixture.clock.advanceUptime(30)

        // when
        await fixture.sut.tick()
        await taskGate.waitUntilBlocked()
        await workflowGate.waitUntilBlocked()
        await fixture.source.waitForDefinitionReadCount(2)
        for _ in 0 ..< 5 { await Task.yield() }

        // then
        #expect(fixture.sut.state == completeState)
        #expect(publications.value == 0)
        await taskGate.release()
        await workflowGate.release()
        await fixture.source.waitForScanReads(2)
        for _ in 0 ..< 5 { await Task.yield() }
        #expect(fixture.sut.state == completeState)
        #expect(publications.value == 0)
        fixture.sut.didDisappear()
    }

    @Test func givenRetriesDuringAnInflightScan_whenRetriedRepeatedly_thenItKeepsSingleFlightAndTheThirtySecondMinimum() async {
        // given
        let taskGate = StartScreenPageGate()
        let workflowGate = StartScreenPageGate()
        let fixture = makeSUT(gate: taskGate, workflowGate: workflowGate, refreshInterval: 30)
        fixture.sut.didAppear()
        await taskGate.waitUntilBlocked()
        await workflowGate.waitUntilBlocked()
        await fixture.source.waitForReadCounts(1)
        let inFlightReads = await fixture.source.counts()

        // when
        fixture.sut.retry()
        await fixture.sut.tick()
        fixture.sut.retry()
        await fixture.sut.tick()
        let afterRetries = await fixture.source.counts()
        await taskGate.release()
        await workflowGate.release()
        await fixture.source.waitForScanReads(1)
        fixture.clock.advanceUptime(30)
        for _ in 0 ..< 20 {
            await Task.yield()
            await fixture.sut.tick()
            let counts = await fixture.source.counts()
            if counts.0 >= 2 { break }
        }
        await waitUntil { !fixture.sut.loading }
        let afterDeadline = await fixture.source.counts()

        // then
        #expect(inFlightReads.0 == 1 && inFlightReads.1 == 1 && inFlightReads.2 == 1)
        #expect(afterRetries.0 == inFlightReads.0 && afterRetries.1 == inFlightReads.1 && afterRetries.2 == inFlightReads.2)
        #expect(afterDeadline.0 == inFlightReads.0 + 1)
        #expect(afterDeadline.1 == inFlightReads.1 + 1)
        #expect(afterDeadline.2 == inFlightReads.2 + 1)
        fixture.sut.didDisappear()
    }

    @Test func givenDefinitionsArePreparing_whenScanCompletes_thenItKeepsTheStartScreenInLoadingState() async {
        // given
        let fixture = makeSUT()
        await fixture.source.setDefinitionsMode(.preparing)
        fixture.sut.didAppear()
        await fixture.source.waitForScanReads(1)
        for _ in 0 ..< 5 { await Task.yield() }

        // then
        #expect(fixture.sut.loading)
        #expect(!fixture.sut.definitionsAvailable)
        #expect(fixture.sut.presentation.rows.isEmpty)
        #expect(fixture.sut.presentation.status == nil)
        fixture.sut.didDisappear()
    }

    @Test func givenDefinitionsFailAfterAVisibleSuccess_whenPolled_thenOldCountsAndChoicesAreCleared() async {
        // given
        let fixture = makeSUT(definitions: [definition("Alpha", workflowID: "alpha")], refreshInterval: 30)
        fixture.sut.didAppear()
        await waitUntil { !fixture.sut.loading }
        #expect(fixture.sut.definitionsAvailable)
        #expect(fixture.sut.presentation.rows.map(\.name) == ["Alpha"])
        await fixture.source.setDefinitionsMode(.failed)

        // when
        fixture.clock.advanceUptime(30)
        await fixture.sut.tick()
        await waitUntil { !fixture.sut.loading && !fixture.sut.definitionsAvailable }

        // then
        #expect(fixture.sut.presentation.status == nil)
        #expect(fixture.sut.presentation.rows.isEmpty)
        #expect(fixture.sut.presentation.total == 0)
        fixture.sut.didDisappear()
    }

    @Test func givenSavedDefinitionIdentityChanges_whenPolled_thenRunCountsStayPinnedToTheOriginalId() async {
        // given
        let run: [String: JSONValue] = [
            "workflow_run_id": .string("run"), "workflow_id": .string("old-id"), "kind": .string("workflow"),
            "status": .string("running"), "settling": .bool(false), "parent_workflow_run_id": .null
        ]
        let fixture = makeSUT(definitions: [definition("Alpha", workflowID: "old-id")], runs: [run], refreshInterval: 30)
        fixture.sut.didAppear()
        await waitUntil { !fixture.sut.loading }
        #expect(fixture.sut.presentation.rows.first?.count == "1 run")
        await fixture.source.setDefinitions([definition("Alpha", workflowID: "new-id")])

        // when
        fixture.clock.advanceUptime(30)
        await fixture.sut.tick()
        await waitUntil { !fixture.sut.loading && fixture.sut.presentation.rows.first?.count == "Never run" }

        // then
        #expect(fixture.sut.definitionsAvailable)
        #expect(fixture.sut.presentation.rows.map(\.name) == ["Alpha"])
        fixture.sut.didDisappear()
    }

    @Test func givenDefinitionReadCompletesAfterDisappear_whenItReturns_thenTheOldMountCannotPublishChoices() async {
        // given
        let definitionsGate = StartScreenPageGate()
        let fixture = makeSUT(definitionsGate: definitionsGate, definitions: [definition("Late", workflowID: "late")])
        fixture.sut.didAppear()
        await definitionsGate.waitUntilBlocked()
        #expect(!fixture.sut.definitionsAvailable)

        // when
        fixture.sut.didDisappear()
        await definitionsGate.release()
        await fixture.source.waitForDefinitionReadCompletion()
        for _ in 0 ..< 5 { await Task.yield() }

        // then
        #expect(fixture.sut.loading)
        #expect(!fixture.sut.definitionsAvailable)
        #expect(fixture.sut.presentation.rows.isEmpty)
    }

    @Test func givenTaskActivityChangesDuringThrottle_whenTicked_thenInvalidatesSnapshotAndCoalescesOneRefresh() async {
        // given
        let fixture = makeSUT(refreshInterval: 30)
        fixture.sut.didAppear()
        await waitUntil { !fixture.sut.loading }
        let originalReads = await fixture.source.counts()

        // when
        fixture.changes.send([task("new", status: "running")])
        await waitUntil { fixture.sut.loading }
        #expect(fixture.sut.presentation.status == nil)
        await fixture.sut.tick()
        fixture.clock.advanceUptime(29)
        await fixture.sut.tick()
        let throttledReads = await fixture.source.counts()
        fixture.clock.advanceUptime(1)
        await fixture.sut.tick()
        await waitUntil { !fixture.sut.loading }
        let refreshedReads = await fixture.source.counts()

        // then
        #expect(throttledReads.0 == originalReads.0)
        #expect(refreshedReads.0 == originalReads.0 + 1)
        #expect(refreshedReads.1 == originalReads.1 + 1)
        #expect(refreshedReads.2 == originalReads.2 + 1)
        fixture.sut.didDisappear()
    }

    @Test func givenScreenRemountsBeforeTheThrottleExpires_whenTicked_thenKeepsSkeletonUntilTheMonotonicDeadline() async {
        // given
        let fixture = makeSUT(refreshInterval: 30)
        fixture.sut.didAppear()
        await waitUntil { !fixture.sut.loading }
        let initialReads = await fixture.source.counts()

        // when
        fixture.sut.didDisappear()
        #expect(fixture.sut.loading)
        #expect(fixture.sut.presentation.status == nil)
        fixture.sut.didAppear()
        await fixture.sut.tick()
        let beforeDeadline = await fixture.source.counts()
        fixture.clock.advanceUptime(29)
        await fixture.sut.tick()
        let justBeforeDeadline = await fixture.source.counts()
        fixture.clock.advanceUptime(1)
        await fixture.sut.tick()
        await waitUntil { !fixture.sut.loading }
        let atDeadline = await fixture.source.counts()

        // then
        #expect(beforeDeadline.0 == initialReads.0)
        #expect(justBeforeDeadline.0 == initialReads.0)
        #expect(atDeadline.0 == initialReads.0 + 1)
        fixture.sut.didDisappear()
    }

    @Test func givenScanIsStillReading_whenScreenDisappears_thenLateResultCannotPublish() async {
        // given
        let gate = StartScreenPageGate()
        let definitionsGate = StartScreenPageGate()
        let fixture = makeSUT(gate: gate, definitionsGate: definitionsGate)
        fixture.sut.didAppear()
        await gate.waitUntilBlocked()
        await definitionsGate.waitUntilBlocked()
        #expect(fixture.sut.loading)

        // when
        fixture.sut.didDisappear()
        await gate.release()
        await definitionsGate.release()
        await fixture.source.waitForTaskReadCompletion()

        // then
        #expect(fixture.sut.loading)
        #expect(fixture.sut.presentation.status == nil)
        #expect(!fixture.sut.definitionsAvailable)
    }
}
