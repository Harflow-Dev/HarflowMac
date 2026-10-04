import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbRepository
import Testing

// MARK: - WorkflowRunPollingTests

@MainActor
@Suite struct WorkflowRunPollingTests {
    @Test func givenPagedExecution_whenPollingTwice_thenAllHistoryLoadsAndUnchangedViewsAreCached() async throws {
        // given
        let useCase = PollingUseCase()
        let loader = WorkflowRunPolling()
        // when
        let first = try await loader.load(id: "run", useCase: useCase)
        let detailCalls = useCase.detailCalls
        let second = try await loader.load(id: "run", useCase: useCase)
        // then
        #expect(first["activations"]?.arrayValue?.count == 2)
        #expect(first["activations"]?.arrayValue?.last?["node_result"]?["result"]?.stringValue == String(repeating: "x", count: 9000))
        #expect(first == second)
        #expect(useCase.detailCalls == detailCalls)
        #expect(useCase.statusOptions == [["--monitor-view"], ["--monitor-view"]])
        #expect(useCase.cursors.contains("page-two"))
    }

    @Test func givenStaleCursor_whenLoading_thenRestartsViewWithoutJoiningDifferentVersions() async throws {
        // given
        let useCase = PollingUseCase()
        useCase.staleOnce = true
        // when
        let result = try await WorkflowRunPolling().load(id: "run", useCase: useCase)
        // then
        #expect(result["activations"]?.arrayValue?.count == 2)
        #expect(useCase.staleRaised)
        #expect(useCase.detailCalls > 3)
    }

    @Test func givenNewBuilderWithoutEditingDefinition_whenHydrated_thenGeneratedDraftIsNotASavedProposal() async throws {
        // given
        let useCase = PollingUseCase()
        // when
        let raw = try await WorkflowRunPolling().load(id: "run", useCase: useCase)
        // then
        #expect(raw["editing_definition"] == nil)
        #expect(!WorkflowRunModel(raw: raw).isBuilderProposal)
    }

    @Test func givenSavedBuilderEditingDefinition_whenHydrated_thenProposalDistinctionIsPreserved() async throws {
        // given
        let useCase = PollingUseCase()
        useCase.editingContent = "{\"nodes\":[]}"
        // when
        let raw = try await WorkflowRunPolling().load(id: "run", useCase: useCase)
        // then
        #expect(raw["editing_definition"]?.objectValue != nil)
        #expect(WorkflowRunModel(raw: raw).isBuilderProposal)
    }

}

// MARK: - PollingUseCase

@MainActor
private final class PollingUseCase: WorkflowUseCase, @unchecked Sendable {
    var backendIDs: [String] { [] }
    var statusOptions: [[String]] = []
    var cursors: [String] = []
    var detailCalls = 0
    var editingContent = "null"
    var staleOnce = false
    var staleRaised = false
    func command(_ command: String, options: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        if command == "status" {
            statusOptions.append(options)
            return ["workflow_run_id": .string("run"), "status": .string("completed"),
                    "kind": .string("builder"),
                    "monitor_digests": .object(["execution_index": .string("execution_index"), "editing_definition": .string("editing_definition")])]
        }
        detailCalls += 1
        let view = String(try #require(options.first { $0.hasPrefix("--view=") }).dropFirst(7))
        let cursor = options.first { $0.hasPrefix("--cursor=") }.map { String($0.dropFirst(9)) }
        if let cursor { cursors.append(cursor) }
        if cursor != nil, staleOnce, !staleRaised {
            staleRaised = true
            throw NSError(domain: "stale", code: 1)
        }
        let content = switch view {
        case "editing_definition": editingContent
        case "execution_index": "[{\"id\":\"a\",\"digest\":\"execution:a\"},{\"id\":\"b\",\"digest\":\"execution:b\"}]"
        case "execution:a": "{\"id\":\"a\",\"status\":\"completed\"}"
        default: "{\"id\":\"b\",\"node_result\":{\"result\":\"\(String(repeating: "x", count: 9000))\"}}"
        }
        let offset = cursor == nil ? 0 : 8000
        let end = min(offset + 8000, content.count)
        let chunk = String(content.dropFirst(offset).prefix(end - offset))
        return ["workflow_run_id": .string("run"), "view": .string(view), "content_sha256": .string(view),
                "offset": .number(Double(offset)), "total_characters": .number(Double(content.count)),
                "chunk": .string(chunk), "next_cursor": end < content.count ? .string("page-two") : .null]
    }

    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { [:] }
    func save(name _: String, definition _: JSONValue, expectedRevision _: Int) async throws -> [String: JSONValue] { [:] }
    func refreshTasks() async {}
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
}
