import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - WorkflowCatalogReadTests

@MainActor
@Suite struct WorkflowCatalogReadTests {
    @Test func givenIdenticalCatalog_whenRefreshed_thenRenderingFieldsStayQuietButFullContentChangesPublish() async {
        // given
        let responses = CatalogReadResponses()
        let vm = WorkflowVM(useCase: CatalogReadUseCase(responses: responses), routing: MockWorkflowRouting(),
                            parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                            visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        let first = Task { await vm.refresh() }
        await waitUntil { responses.count == 1 }
        responses.finish(0, response: Self.catalog("one"))
        await first.value
        let changes = CatalogObservationChanges()
        withObservationTracking {
            _ = vm.workflows
            _ = vm.hasLoadedWorkflowList
        } onChange: { changes.mark() }
        // when
        let second = Task { await vm.refresh() }
        await waitUntil { responses.count == 2 }
        responses.finish(1, response: Self.catalog("one"))
        await second.value
        // then
        #expect(!changes.changed)
        let third = Task { await vm.refresh() }
        await waitUntil { responses.count == 3 }
        responses.finish(2, response: Self.catalog("two"))
        await third.value
        #expect(changes.changed)
        #expect(vm.workflows.first?.raw["future"] == .string("two"))
    }

    @Test(arguments: ["success", "error", "preparing"])
    func givenOlderCatalogRead_whenNewerReadCompletesFirst_thenOlderCompletionIsInert(_ kind: String) async {
        // given
        let responses = CatalogReadResponses()
        let vm = WorkflowVM(useCase: CatalogReadUseCase(responses: responses), routing: MockWorkflowRouting(),
                            parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
                            visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        let older = Task { await vm.refresh() }
        await waitUntil { responses.count == 1 }
        let newer = Task { await vm.refresh() }
        await waitUntil { responses.count == 2 }
        responses.finish(1, response: Self.catalog("new"))
        await newer.value
        // when
        let stale: [String: JSONValue] = kind == "preparing" ? ["bootstrap_pending": .bool(true)]
            : kind == "error" ? [:] : Self.catalog("old")
        responses.finish(0, response: stale)
        await older.value
        // then
        #expect(vm.workflows.first?.raw["future"] == .string("new"))
        #expect(vm.hasLoadedWorkflowList)
        #expect(vm.readFailures.isEmpty)
    }

    @Test(arguments: [false, true])
    func givenOwnedPreparation_whenReplacedOrDisappearing_thenCancelsObsoleteWork(_ disappearing: Bool) async {
        // given
        let harness = WorkflowTests().makeVM()
        let gate = OwnedCatalogPreparationGate()
        let obsolete = Task.detached {
            await gate.wait()
            return try WorkflowDefinitionCatalog.prepare(Self.catalog("obsolete"))
        }
        harness.sut.catalogPreparationTask = obsolete
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn(Self.catalog("current"))
        // when
        if disappearing { harness.sut.didDisappear() } else { await harness.sut.refresh() }
        await gate.open()
        // then
        await #expect(throws: CancellationError.self) { try await obsolete.value }
        #expect(harness.sut.catalogPreparationTask == nil)
    }

    private nonisolated static func catalog(_ content: String) -> [String: JSONValue] {
        ["workflows": .array([.object(["name": .string("same"), "future": .string(content)])])]
    }
}

private final class CatalogReadResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [Int: CheckedContinuation<[String: JSONValue], Never>] = [:]
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func read() async -> [String: JSONValue] {
        await withCheckedContinuation { continuation in
            lock.withLock {
                pending[calls] = continuation
                calls += 1
            }
        }
    }

    func finish(_ index: Int, response: [String: JSONValue]) {
        lock.withLock { pending.removeValue(forKey: index) }?.resume(returning: response)
    }
}

private final class CatalogObservationChanges: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var changed: Bool { lock.withLock { value } }
    func mark() { lock.withLock { value = true } }
}

private actor OwnedCatalogPreparationGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct CatalogReadUseCase: WorkflowUseCase {
    let responses: CatalogReadResponses
    var backendIDs: [String] { [] }
    func command(_: String, options _: [String], positionals _: [String], runtime _: QualificationRuntimeToken?) async throws -> [String: JSONValue] {
        await responses.read()
    }

    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { [:] }
    func save(name _: String, definition _: JSONValue, expectedRevision _: Int, expectedWorkflowID _: String?) async throws -> [String: JSONValue] { [:] }
    func refreshTasks() async {}
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
}
