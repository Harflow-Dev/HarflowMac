import Combine
import Foundation
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - M05Fixtures

/// Builders shared by the M05 matrix suites. Every harness is a real `TaskDetailVM` behind the strict use-case mock, with the
/// answers each state needs; nothing here changes product behaviour.
@MainActor enum M05Fixtures {
    static let taskID = TopBarIntegratedFixture.taskID

    /// A task record in the shape the engine's `status` returns, with the fields the matrix states vary.
    static func task(status: String, liveInput: Bool = true, fields: [String: JSONValue] = [:]) -> TaskInfo {
        var raw: [String: JSONValue] = [
            "task_id": .string(taskID), "backend": .string("claude"), "status": .string(status),
            "repo_path": .string("/repo"), "live_input": .bool(liveInput), "taken_over": .bool(false),
            "started_at": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90))),
            "session_id": .string("fixture-session"), "freedom": .string("write_in_repo"),
            "supervision": .object(["owner_state": .string("alive")])
        ]
        for (key, value) in fields { raw[key] = value }
        guard let info = TaskInfo(.object(raw)) else { preconditionFailure("The M05 matrix task is not a task") }
        return info
    }

    /// A finished task whose snapshot matches and carries an observed exit, so no uncertainty treatment applies.
    static func settled(status: String = "completed", exit: Int = 0, fields: [String: JSONValue] = [:]) -> TaskInfo {
        var merged: [String: JSONValue] = ["exit_code": .number(Double(exit)), "resume_command": .string("fixture resume " + taskID)]
        for (key, value) in fields { merged[key] = value }
        return task(status: status, fields: merged)
    }

    /// A harness for `task`. The snapshot defaults to the task itself (a matching read). Stored changes answer as unreadable
    /// unless the state replaces `readChanges` before the shell mounts through the returned `Built.prepare`.
    static func harness(_ task: TaskInfo?, snapshot: TaskInfo?? = nil, fixtures: TaskDetailVMTests.Fixtures = .init(),
                        stubChanges: Bool = true) -> TaskDetailVMTests.SUT {
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.detailBox.value = task
        switch snapshot {
        case .none: harness.snapshotBox.value = task
        case .some(let value): harness.snapshotBox.value = value
        }
        if stubChanges { stubUnreadableChanges(harness) }
        return harness
    }

    static func stubUnreadableChanges(_ harness: TaskDetailVMTests.SUT) {
        given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, _ in
            .failure(TaskChangesReadFailure(key: key, outcome: .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "unavailable"))))
        }
    }

    /// An observation frame for the matrix task with the given facts. Items default to none.
    static func frame(items: [TimelineItem] = [], history: EventObservationHistory = .init(caughtUp: true, forwardDrained: true),
                      logState: EventLogState? = .final, summary: ObservedActivitySummary = .init(),
                      scope: EventObservationScope = FeatureObservationFixture.scope) -> EventObservationFrame {
        EventObservationFrame(taskID: taskID, scope: scope, items: items, history: history, summary: summary, logState: logState)
    }

    /// Publishes `frame` as the VM's observation, as the repository's publisher would.
    static func publish(_ frame: EventObservationFrame, to harness: TaskDetailVMTests.SUT) {
        harness.observationBox.value = frame
        harness.observationSubject.send(frame)
    }

    /// A text row for a transcript.
    static func text(_ seq: Int, _ text: String) -> TimelineItem { SummaryEntryScenario.text(seq, text) }

    /// Answers the per-member reads a conversation's other turn needs, as `HostedContinuationFixture.installMember` does.
    static func installMember(_ member: TaskInfo, conversation: [TaskInfo], on harness: TaskDetailVMTests.SUT) {
        let useCase = harness.useCase
        let id = member.taskID
        given(useCase).detail(.value(id)).willReturn(member)
        given(useCase).conversationMembers(of: .value(id)).willReturn(conversation)
        given(useCase).snapshot(.value(id)).willReturn(member)
        given(useCase).refreshSnapshot(.value(id)).willReturn()
        given(useCase).children(of: .value(id)).willReturn([])
        given(useCase).siblings(of: .value(id)).willReturn([])
        given(useCase).activity(for: .value(id)).willReturn(ActivityCounts())
        given(useCase).current(for: .value(id)).willReturn(nil)
        given(useCase).prompt(for: .value(id)).willReturn(nil)
        given(useCase).events(for: .value(id)).willReturn([])
        given(useCase).items(for: .value(id)).willReturn([])
        given(useCase).eventsAvailability(for: .value(id)).willReturn(.available)
        given(useCase).eventsAvailabilityPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).itemsPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).observation(for: .value(id)).willReturn(FeatureObservationFixture.frame(id: id, availability: .available))
        given(useCase).observationPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).recoveredTranscript(for: .value(id)).willReturn(RecoveredTranscriptFrame())
        given(useCase).recoveredTranscriptPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).requestState(for: .value(id)).willReturn(.notRequested)
        given(useCase).requestPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        let lease = MockEventStreamLease()
        given(lease).taskID.willReturn(id)
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value(id)).willReturn(lease)
    }
}
