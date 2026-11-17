import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore

// MARK: - LibraryTestUseCase

@MainActor final class LibraryTestUseCase: WorkflowLibraryUseCase {
    var selected = LibraryTestUseCase.context("A")
    var response: [String: JSONValue] = ["workflows": .array([.object([
        "name": .string("implement-review"), "definition": .object(["nodes": .array([])])
    ])])]
    var failure: Error?
    var contexts: [WorkflowResponseContext] = []
    var suspended = false
    var pending: CheckedContinuation<[String: JSONValue], any Error>?

    static func context(_ name: String) -> WorkflowResponseContext {
        WorkflowResponseContext(runtime: QualificationRuntimeToken(client: CtlClient(executable: "/fixture/" + name, environment: [:])), epoch: UUID())
    }

    func context() throws -> WorkflowResponseContext { selected }
    func isCurrent(_ context: WorkflowResponseContext) -> Bool { selected == context }
    func list(context: WorkflowResponseContext) async throws -> [String: JSONValue] {
        contexts.append(context)
        if suspended { return try await withCheckedThrowingContinuation { pending = $0 } }
        if let failure { throw failure }
        return response
    }

    func finish() { let continuation = pending; pending = nil; continuation?.resume(returning: response) }
}

// MARK: - LibraryTestRouting

@MainActor final class LibraryTestRouting: WorkflowLibraryRouting {
    var edits: [String] = []
    var runs: [String] = []
    var creations: [Bool] = []
    func editLibraryWorkflow(name: String) { edits.append(name) }
    func runLibraryWorkflow(name: String) { runs.append(name) }
    func newLibraryWorkflow(generate: Bool) { creations.append(generate) }
}

// MARK: - LibraryTestHarness

@MainActor struct LibraryTestHarness {
    let useCase = LibraryTestUseCase()
    let routing = LibraryTestRouting()
    let scheduler = CapturingScheduler()
    let visibility = FakeMonitorVisibility()
    let vm: WorkflowLibraryVM

    init() {
        self.vm = WorkflowLibraryVM(useCase: useCase, routing: routing, visibility: visibility, scheduler: scheduler)
    }
}
