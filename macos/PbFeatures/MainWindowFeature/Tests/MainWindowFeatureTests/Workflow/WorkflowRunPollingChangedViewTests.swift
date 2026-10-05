import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbRepository
import Testing

@MainActor
struct WorkflowRunPollingChangedViewTests {
    @Test func givenFrozenBootstrap_whenOnlySummaryChanges_thenOnlyChangedViewPagesLoadWithoutAnotherSnapshot() async throws {
        let useCase = ChangedViewPollingUseCase()
        let loader = WorkflowRunPolling()
        let initial = try await loader.load(id: "run", useCase: useCase)
        #expect(useCase.detailViews == ["execution_index"])
        useCase.detailViews = []
        useCase.summary = String(repeating: "new", count: 100)
        let refreshed = try await loader.load(id: "run", useCase: useCase)
        #expect(refreshed["summary"]?.stringValue == useCase.summary)
        #expect(refreshed["activations"] == initial["activations"])
        #expect(Set(useCase.detailViews) == ["summary"])
        #expect(useCase.detailViews.count > 1, "changed view retains cursor paging")
        #expect(useCase.statusOptions == [["--monitor-view", "--snapshot"], ["--monitor-view"]])
    }

    @Test func givenIndexAdvancesDuringFrozenBootstrap_whenSeedingFails_thenFrozenSnapshotRemainsUsable() async throws {
        let useCase = ChangedViewPollingUseCase()
        useCase.failIndex = true
        let loader = WorkflowRunPolling()
        let raw = try await loader.load(id: "run", useCase: useCase)
        #expect(raw["summary"]?.stringValue == "initial")
        #expect(raw["activations"]?.arrayValue?.count == 2)
        #expect(loader.cached(id: "run") == raw)
        #expect(useCase.statusOptions == [["--monitor-view", "--snapshot"]])
        #expect(useCase.detailViews == ["execution_index", "execution_index"])
    }

    @Test func givenIndexedFrozenHistory_whenOneExecutionAdvances_thenOnlyThatExecutionIsDownloaded() async throws {
        let useCase = ChangedViewPollingUseCase()
        let loader = WorkflowRunPolling()
        _ = try await loader.load(id: "run", useCase: useCase)
        useCase.detailViews = []
        useCase.executionStatus = "completed"
        let refreshed = try await loader.load(id: "run", useCase: useCase)
        #expect(Set(useCase.detailViews) == ["execution_index", "execution:live"])
        #expect(refreshed["activations"]?.arrayValue?.last?["status"]?.stringValue == "completed")
        #expect(useCase.statusOptions.last == ["--monitor-view"])
        useCase.detailViews = []
        useCase.status = "needs_input"
        let statusOnly = try await loader.load(id: "run", useCase: useCase)
        #expect(statusOnly["status"]?.stringValue == "needs_input")
        #expect(useCase.detailViews.isEmpty)
        #expect(useCase.statusOptions.last == ["--monitor-view"])
    }
}

@MainActor
private final class ChangedViewPollingUseCase: WorkflowUseCase, @unchecked Sendable {
    var backendIDs: [String] { [] }
    var summary = "initial"
    var executionStatus = "running"
    var status = "running"
    var failIndex = false
    var detailViews: [String] = []
    var statusOptions: [[String]] = []
    private var old: JSONValue { .object(["id": .string("old"), "status": .string("completed")]) }
    private var live: JSONValue { .object(["id": .string("live"), "status": .string(executionStatus)]) }
    private var index: JSONValue { .array([.object(["id": .string("old"), "digest": .string("old")]),
        .object(["id": .string("live"), "digest": .string(executionStatus)])]) }
    func command(_ command: String, options: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        if command == "status" {
            statusOptions.append(options)
            let raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "status": .string(status),
                "summary": .string(summary), "activations": .array([old, live]),
                "monitor_digests": .object(["summary": .string(summary), "execution_index": .string(executionStatus)])]
            if options.contains("--snapshot") {
                let text = JSONValue.object(raw).rendered()
                return ["monitor_snapshot": .bool(true), "workflow_run_id": .string("run"), "chunk": .string(text),
                    "content_sha256": .string("snapshot"), "offset": .number(0), "total_characters": .number(Double(text.utf8.count)), "next_cursor": .null]
            }
            return raw.filter { !["summary", "activations"].contains($0.key) }
        }
        #expect(options.contains("--monitor-view"), "detail continuations use immutable bounded transport")
        let view = String(try #require(options.first { $0.hasPrefix("--view=") }).dropFirst(7))
        detailViews.append(view)
        if view == "execution_index", failIndex { throw NSError(domain: "stale index", code: 1) }
        let value: JSONValue = view == "summary" ? .string(summary) : view == "execution_index" ? index : live
        let text = value.rendered()
        let digest = view == "summary" ? summary : executionStatus
        let offset = options.first { $0.hasPrefix("--cursor=") }.flatMap { Int($0.dropFirst(9)) } ?? 0
        let end = view == "summary" ? min(offset + 40, text.utf8.count) : text.utf8.count
        return ["workflow_run_id": .string("run"), "view": .string(view), "content_sha256": .string(digest),
            "offset": .number(Double(offset)), "total_characters": .number(Double(text.utf8.count)),
            "chunk": .string(String(text.dropFirst(offset).prefix(end - offset))), "next_cursor": end < text.utf8.count ? .string("\(end)") : .null]
    }

    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { [:] }
    func save(name _: String, definition _: JSONValue, expectedRevision _: Int) async throws -> [String: JSONValue] { [:] }
    func refreshTasks() async {}
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
}
