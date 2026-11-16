import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

// MARK: - MessagingSubmissionTests

@Suite struct MessagingSubmissionTests {
    private func makeSUT(
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        taskListRepository: MockTaskListRepository = MockTaskListRepository(),
        snapshotRepository: MockTaskSnapshotRepository = MockTaskSnapshotRepository()
    ) -> TaskActionRepositoryImpl {
        given(taskListRepository).tasks.willReturn([])
        given(taskListRepository).tasksPublisher().willReturn(Just([]).eraseToAnyPublisher())
        given(snapshotRepository).readRevision.willReturn(0)
        given(snapshotRepository).readOutcomes.willReturn([:])
        given(snapshotRepository).readChangesPublisher().willReturn(Just(.updated).eraseToAnyPublisher())
        given(taskListRepository).refresh().willReturn()
        given(snapshotRepository).refresh(.any).willReturn()
        return TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskListRepository, snapshotRepository: snapshotRepository)
    }

    @Test(arguments: [false, true])
    func givenUnconfirmedSend_whenCalledAgain_thenEarlierAttemptIsRetainedAndNoReplay(now: Bool) async throws {
        // given
        let tooling = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        given(tooling).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: PositiveCtlRunner(runner))))
        let sut = makeSUT(toolEnvironment: tooling)
        let id = String(repeating: "a", count: 32)
        // when
        let first = try await sut.submitMessage(id, text: "identical text", now: now, acknowledgingUnconfirmed: nil)
        do {
            _ = try await sut.submitMessage(id, text: "identical text", now: now, acknowledgingUnconfirmed: nil)
            Issue.record("Unresolved send must require an explicit warning acknowledgement")
        } catch {
            #expect(error as? MessagingAdmissionError == .previousUnconfirmed(first.id))
        }
        // then — a status refresh, even with identical text from another caller, never rewrites this evidence.
        #expect(first.isUnconfirmed)
        #expect(sut.isMessagingAttemptCurrent(first))
        #expect(sut.messageAttempts() == [first])
        #expect(runner.calls.filter { $0.arguments.first == "send" }.count == 1)
    }

    @Test func givenCancelTimeout_whenCalledAgain_thenNoFabricatedCancellationOrReplay() async throws {
        // given
        let tooling = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        given(tooling).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: PositiveCtlRunner(runner))))
        let sut = makeSUT(toolEnvironment: tooling)
        let task = String(repeating: "a", count: 32)
        let message = String(repeating: "b", count: 32)
        // when
        let first = try await sut.cancelQueuedMessage(task, messageID: message)
        do {
            _ = try await sut.cancelQueuedMessage(task, messageID: message)
            Issue.record("Cancel must not replay an unresolved request")
        } catch { #expect(error as? MessagingAdmissionError == .previousUnconfirmed(first.id)) }
        // then
        guard case .cancel(.unconfirmed) = first.outcome else { Issue.record("Expected unconfirmed cancellation"); return }
        #expect(runner.calls.filter { $0.arguments.first == "cancel-message" }.count == 1)
    }

    @Test func givenRuntimeABAWhileSending_whenReplyArrives_thenOldAttemptRetainedWithoutCurrentRefresh() async throws {
        // given
        let states = LockedBox(CurrentValueSubject<ManagedRuntimeState, Never>(.preparing))
        let tooling = MockToolEnvironmentRepository()
        let runner = StubProcessRunner { _ in
            states.value.send(.installing)
            states.value.send(.preparing)
            return .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        }
        given(tooling).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: PositiveCtlRunner(runner))))
        let snapshots = MockTaskSnapshotRepository()
        let sut = makeSUT(toolEnvironment: tooling, snapshotRepository: snapshots)
        sut.bindMessagingRuntimeChanges(states.value.eraseToAnyPublisher())
        // when
        let attempt = try await sut.submitMessage(String(repeating: "a", count: 32), text: "keep", now: false, acknowledgingUnconfirmed: nil)
        // then
        #expect(attempt.isUnconfirmed)
        #expect(sut.messageAttempts().first?.id == attempt.id)
        #expect(sut.messageAttempts().first?.runtime == attempt.runtime)
        #expect(attempt.runtimeEpoch != sut.messagingEpoch)
        #expect(!sut.isMessagingAttemptCurrent(attempt))
        verify(snapshots).refresh(.any).called(0)
    }

    @Test(arguments: ["aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "release_task-1", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"])
    func givenObservedFullTaskID_whenSubmitting_thenExactIdentityReachesCtl(id: String) async throws {
        // given
        let tooling = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        given(tooling).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: PositiveCtlRunner(runner))))
        let sut = makeSUT(toolEnvironment: tooling)
        // when
        let attempt = try await sut.submitMessage(id, text: "kept", now: false, acknowledgingUnconfirmed: nil)
        // then
        #expect(attempt.taskID == id)
        #expect(runner.calls.first(where: { $0.arguments.first == "send" })?.arguments.suffix(2) == [id, "kept"])
    }

    @Test(arguments: [false, true])
    func givenUnconfirmedSend_whenDeliveryModeChanges_thenAcknowledgementStillRequired(now: Bool) async throws {
        // given
        let tooling = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        given(tooling).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: PositiveCtlRunner(runner))))
        let sut = makeSUT(toolEnvironment: tooling)
        let taskID = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        let text = "  exact draft text  "
        let first = try await sut.submitMessage(taskID, text: text, now: now, acknowledgingUnconfirmed: nil)
        // when
        do {
            _ = try await sut.submitMessage(taskID, text: text, now: !now, acknowledgingUnconfirmed: nil)
            Issue.record("Changing delivery mode must not bypass the unconfirmed-send warning")
        } catch {
            #expect(error as? MessagingAdmissionError == .previousUnconfirmed(first.id))
        }
        // then
        #expect(sut.messageAttempts() == [first])
        let calls = runner.calls.filter { $0.arguments.first == "send" }
        #expect(calls.count == 1)
        #expect(calls.first?.arguments == ["send", "--delivery=\(now ? "now" : "queue")", "--monitor", "--json", "--", taskID, text])
    }

    @Test(arguments: [false, true])
    func givenClickTimeContext_whenRuntimeChangesBeforeAdmission_thenNoCancellationIsDispatched(aba: Bool) async throws {
        // given
        let states = CurrentValueSubject<ManagedRuntimeState, Never>(.preparing)
        let tooling = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        given(tooling).ctl().willReturn(.success(CtlClient(executable: "/fake/ctl", environment: [:], runner: PositiveCtlRunner(runner))))
        let sut = makeSUT(toolEnvironment: tooling)
        sut.bindMessagingRuntimeChanges(states.eraseToAnyPublisher())
        let context = try sut.messageCancellationContext()
        states.send(.installing)
        if aba { states.send(.preparing) }
        // when
        do {
            _ = try await sut.cancelQueuedMessage("full-task-id", messageID: String(repeating: "b", count: 32), context: context)
            Issue.record("Stale click-time authority must refuse admission")
        } catch { #expect(error as? MessagingAdmissionError == .runtimeChanged) }
        // then
        #expect(sut.messageAttempts().isEmpty)
        #expect(runner.calls.isEmpty)
    }
}
