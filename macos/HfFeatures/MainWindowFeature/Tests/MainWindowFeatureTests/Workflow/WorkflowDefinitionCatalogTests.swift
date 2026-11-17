import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowDefinitionCatalogTests

@Suite struct WorkflowDefinitionCatalogTests {
    @Test func givenOrderedDefinitionsWithAdditiveFields_whenPrepared_thenPreservesFullRecordsAndOrder() throws {
        // given
        let rows: [[String: JSONValue]] = [
            ["name": .string("z"), "future": .object(["nested": .array([.number(3)])])],
            ["name": .string("a"), "definition": .object(["description": .string("kept")])]
        ]
        // when
        let result = try WorkflowDefinitionCatalog.prepare(["workflows": .array(rows.map(JSONValue.object))])
        // then
        guard case let .ready(records) = result else { Issue.record("Expected ready catalog"); return }
        #expect(records == rows.map(WorkflowRecord.init(raw:)))
        #expect(records.map(\.id) == ["z", "a"])
    }

    @Test(arguments: [JSONValue.null, .object([:]), .array([.string("bad")]),
                      .array([.object(["name": .string(" \n")])]),
                      .array([.object(["name": .string("same")]), .object(["name": .string("same")])])])
    func givenInvalidDefinitions_whenPrepared_thenRejectsWholeCatalog(_ value: JSONValue) {
        // given / when / then
        #expect(throws: WorkflowDefinitionCatalog.ReadError.incomplete) {
            try WorkflowDefinitionCatalog.prepare(["workflows": value])
        }
    }

    @Test func givenMissingArray_whenPrepared_thenRejectsRatherThanTreatingAsEmpty() {
        // given / when / then
        #expect(throws: WorkflowDefinitionCatalog.ReadError.incomplete) { try WorkflowDefinitionCatalog.prepare([:]) }
    }

    @Test func givenUnavailableCatalogs_whenPrepared_thenPreservesStateAndReasonBeforeSchemaValidation() throws {
        // given / when
        let preparing = try WorkflowDefinitionCatalog.prepare(["bootstrap_pending": .bool(true)])
        let blocked = try WorkflowDefinitionCatalog.prepare([
            "catalog_state": .object(["status": .string("blocked"), "reason": .string("large record")])
        ])
        // then
        guard case .preparing = preparing else { Issue.record("Expected preparation"); return }
        guard case .blocked("large record") = blocked else { Issue.record("Expected retained blocked reason"); return }
    }

    @Test(arguments: ["preparing", "blocked", "malformed"])
    func givenUnavailableSharedCatalog_whenScannerAdapts_thenPreservesScannerErrorVocabulary(_ state: String) {
        // given
        let response: [String: JSONValue] = state == "malformed" ? [:]
            : ["catalog_state": .object(["status": .string(state)])]
        // when / then
        if state == "preparing" {
            #expect(throws: StartScreenHistoryScanner.ScanError.preparing) {
                try StartScreenHistoryRepository.parseDefinitions(response: response)
            }
        } else {
            #expect(throws: StartScreenHistoryScanner.ScanError.incomplete) {
                try StartScreenHistoryRepository.parseDefinitions(response: response)
            }
        }
    }

    @MainActor
    @Test func givenStartedBackgroundPreparation_whenParentIsCancelled_thenCancelsOwnedWork() async {
        // given
        let gate = CatalogParserGate()
        let entered = CatalogPreparationEntry()
        let work = WorkflowCatalogPreparation.start(["workflows": .array([])]) { response in
            entered.markCurrentThread()
            await gate.wait()
            return try WorkflowDefinitionCatalog.prepare(response)
        }
        let parent = Task { try await WorkflowCatalogPreparation.value(of: work) }
        await waitUntil { entered.started }
        #expect(entered.started)
        #expect(!entered.mainThread)
        // when
        parent.cancel()
        await gate.open()
        // then
        await #expect(throws: CancellationError.self) { try await parent.value }
        #expect(work.isCancelled)
    }

    @Test func givenCancelledPreparation_whenParsed_thenStopsWithoutReturningCatalog() async {
        // given
        let gate = CatalogParserGate()
        let task = Task.detached {
            await gate.wait()
            return try WorkflowDefinitionCatalog.prepare(["workflows": .array([])])
        }
        // when
        task.cancel()
        await gate.open()
        // then
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

private actor CatalogParserGate {
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

private final class CatalogPreparationEntry: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var onMain = true
    var started: Bool { lock.withLock { didStart } }
    var mainThread: Bool { lock.withLock { onMain } }
    func markCurrentThread() {
        let mainThread = Thread.isMainThread
        lock.withLock { didStart = true; onMain = mainThread }
    }
}
