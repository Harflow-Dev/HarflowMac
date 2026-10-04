import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbRepository

// MARK: - ControlledWorkflowValidationUseCase

@MainActor
final class ControlledWorkflowValidationUseCase: WorkflowUseCase, @unchecked Sendable {
    var requests: [[String: JSONValue]] = []
    var savedRequests: [[String: JSONValue]] = []
    var delayRefresh = false
    var pendingRefresh: CheckedContinuation<[String: JSONValue], Never>?
    var pendingLoad: CheckedContinuation<[String: JSONValue], Never>?
    private var pendingSave: CheckedContinuation<[String: JSONValue], Never>?
    private var pending: [Int: CheckedContinuation<[String: JSONValue], any Error>] = [:]
    var backendIDs: [String] { ["codex"] }

    func validate(definition: JSONValue) async throws -> [String: JSONValue] {
        let index = requests.count
        requests.append(definition.objectValue ?? [:])
        return try await withCheckedThrowingContinuation { pending[index] = $0 }
    }

    func finish(_ index: Int, result: Result<[String: JSONValue], any Error>) {
        pending.removeValue(forKey: index)?.resume(with: result)
    }

    func command(_ command: String, options _: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        if ["list", "status"].contains(command), delayRefresh {
            return await withCheckedContinuation { pendingRefresh = $0 }
        }
        guard command == "get" else { return [:] }
        return await withCheckedContinuation { pendingLoad = $0 }
    }

    func finishRefresh() {
        pendingRefresh?.resume(returning: [:])
        pendingRefresh = nil
    }

    func finishAllValidations() {
        for index in Array(pending.keys) { finish(index, result: .success(["valid": .bool(true)])) }
    }

    func finishLoad(_ response: [String: JSONValue]) {
        pendingLoad?.resume(returning: response)
        pendingLoad = nil
    }

    func save(name _: String, definition: JSONValue, expectedRevision _: Int) async throws -> [String: JSONValue] {
        savedRequests.append(definition.objectValue ?? [:])
        return await withCheckedContinuation { pendingSave = $0 }
    }

    func finishSave(_ response: [String: JSONValue]) {
        pendingSave?.resume(returning: response)
        pendingSave = nil
    }

    func refreshTasks() async {}
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
}
