import Combine
import Foundation
@testable import HfRepository
@testable import MainWindowFeature
import MonitorCore

// MARK: - ContinuationUITestOwner

/// Synchronous owner snapshots can change while their UI invalidation is deliberately withheld.
final class ContinuationUITestOwner: TaskContinuationRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var record: TaskContinuationAttempt?
    private var starts = 0
    private var checks = 0
    let changes = PassthroughSubject<Void, Never>()
    let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/harflow-ctl", environment: [:]))

    var startCount: Int { lock.withLock { starts } }
    var checkCount: Int { lock.withLock { checks } }

    func install(_ outcome: ConversationLaunchOutcome?, source: String = "abc12345", proof: [String] = []) {
        lock.withLock {
            record = TaskContinuationAttempt(id: UUID(), request: .init(runtime: runtime, conversationID: "abc12345", sourceTaskID: source),
                                             outcome: outcome, check: .notChecked, recordedSuccessorTaskIDs: proof)
        }
    }

    func state(for request: TaskContinuationRequest) -> TaskContinuationAttempt? {
        lock.withLock { record?.request.runtime == request.runtime ? record : nil }
    }

    func changesPublisher() -> AnyPublisher<Void, Never> { changes.eraseToAnyPublisher() }

    func start(_ request: TaskContinuationRequest) async -> TaskContinuationAdmission {
        lock.withLock {
            if let record { return .existing(record.id) }
            starts += 1
            let attempt = TaskContinuationAttempt(id: UUID(), request: request, outcome: nil, check: .notChecked)
            record = attempt
            return .started(attempt.id)
        }
    }

    func check(attemptID _: UUID) async { lock.withLock { checks += 1 } }
    func check(attemptID _: UUID, targetSourceTaskID _: String) async { lock.withLock { checks += 1 } }
}

@MainActor
struct ContinuationUIFixture {
    let owner = ContinuationUITestOwner()
    let fixtures = TaskDetailVMTests.Fixtures()
    let vm: TaskDetailVMTests.SUT

    init(status: String = "failed", exit: Bool = true, supported: Bool = true, chrome: TaskDetailChrome = .standalone) {
        let owner = owner
        fixtures.continuationOwner.value = owner
        fixtures.continuationRuntime.value = owner.runtime
        fixtures.continuationSupport.value = supported
        let task = Self.task(status: status, exit: exit)
        fixtures.detailBox.value = task
        fixtures.snapshotBox.value = task
        self.vm = TaskDetailVMTests().makeSUT(chrome: chrome, fixtures: fixtures)
    }

    static func task(id: String = "abc12345", status: String = "failed", exit: Bool = true, predecessor: String? = nil) -> TaskInfo {
        var raw: [String: JSONValue] = ["task_id": .string(id), "status": .string(status), "backend": .string("claude"),
                                      "session_id": .string("fixture-session"), "live_input": .bool(true),
                                      "resume_command": .string("fixture resume " + id)]
        if exit { raw["exit_code"] = .number(1) }
        if let predecessor { raw["continuation_of_task_id"] = .string(predecessor) }
        return TaskInfo(.object(raw))!
    }
}
