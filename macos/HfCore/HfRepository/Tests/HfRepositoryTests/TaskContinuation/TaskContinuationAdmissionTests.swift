import Combine
import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - TaskContinuationAdmissionTests

struct TaskContinuationAdmissionTests {
    @Test func givenParkedInvocation_whenAliasesAndOtherSourceStart_thenOneInvocationOwnsConversation() async throws {
        // given
        let latch = ContinuationLatch()
        let harness = ContinuationHarness(runner: ContinuationRunner(latch: latch))
        let request = harness.request()
        let first = Task { await harness.repository.start(request) }
        await latch.waitForArrival()
        let initial = try #require(harness.repository.state(for: request))
        // when
        let alias = await harness.repository.start(harness.request(conversation: "alias"))
        let other = await harness.repository.start(harness.request("other"))
        // then
        #expect(initial.outcome == nil)
        #expect(alias == .existing(initial.id))
        #expect(other == .existing(initial.id))
        #expect(!harness.actions.tryBeginBusy("source"))
        #expect(await harness.runner.commands.count == 1)
        await latch.release()
        #expect(await first.value == .started(initial.id))
        #expect(harness.actions.tryBeginBusy("source"))
        harness.actions.endBusy("source")
        #expect(harness.repository.state(for: request)?.outcome == .launched(taskID: "accepted"))
    }

    @Test func givenUnknown_whenRepeatedOrAliased_thenOriginalAttemptAndOutcomeRemain() async throws {
        // given
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(task: nil)))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        let repeated = await harness.repository.start(harness.request())
        let alias = await harness.repository.start(harness.request(conversation: "alias"))
        // then
        #expect(repeated == .existing(original.id))
        #expect(alias == .existing(original.id))
        #expect(harness.repository.state(for: harness.request()) == original)
        #expect(await harness.runner.commands.count == 1)
        #expect(harness.actions.tryBeginBusy("source"))
        harness.actions.endBusy("source")
    }

    @Test func givenEngineError_whenExplicitlyRetried_thenFreshAttemptRetainsEarlierEvidence() async throws {
        // given
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(error: "failed", exit: 1)))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        await harness.runner.setOutput(continuationOutput())
        let retry = await harness.repository.start(harness.request())
        let current = try #require(harness.repository.state(for: harness.request()))
        // then
        #expect(current.id != original.id)
        #expect(retry == .started(current.id))
        #expect(current.outcome == .launched(taskID: "accepted"))
        #expect(await harness.runner.commands.count == 2)
    }

    @Test func givenBusyOrMissingFullIdentity_whenStartRequested_thenNoInvocationAndNoRetainedReservation() async {
        // given
        let harness = ContinuationHarness()
        #expect(harness.actions.tryBeginBusy("source"))
        // when
        let busy = await harness.repository.start(harness.request())
        let missing = await harness.repository.start(harness.request("sou"))
        // then
        #expect(busy == .refused(.busy))
        #expect(missing == .refused(.missingIdentity))
        #expect(harness.repository.state(for: harness.request()) == nil)
        #expect(await harness.runner.commands.isEmpty)
        harness.actions.endBusy("source")
        guard case .started = await harness.repository.start(harness.request()) else { Issue.record("Explicit retry should admit"); return }
    }

    @Test func givenRuntimeABA_whenOldUnknownIsRevisited_thenOldAttemptStillBlocks() async throws {
        // given
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(task: nil)))
        let originalClient = harness.selected.value
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        let replacement = CtlClient(executable: "/fixture/replacement/ctl", environment: [:], runner: harness.runner)
        harness.selected.mutate { $0 = replacement }
        let otherRequest = TaskContinuationRequest(runtime: QualificationRuntimeToken(client: replacement),
                                                         conversationID: "conversation", sourceTaskID: "source")
        _ = await harness.repository.start(otherRequest)
        // when
        harness.selected.mutate { $0 = originalClient }
        let result = await harness.repository.start(harness.request())
        // then
        #expect(result == .existing(original.id))
        #expect(harness.repository.state(for: harness.request()) == original)
        #expect(await harness.runner.commands.count == 2)
    }

    @Test func givenDispatchedCommand_whenCallerCancelsAndRuntimeChanges_thenAcknowledgementIsRetained() async throws {
        // given
        let latch = ContinuationLatch()
        let harness = ContinuationHarness(runner: ContinuationRunner(latch: latch))
        let operation = Task { await harness.repository.start(harness.request()) }
        await latch.waitForArrival()
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        operation.cancel()
        harness.selected.mutate { $0 = CtlClient(executable: "/fixture/replacement/ctl", environment: [:]) }
        await latch.release()
        _ = await operation.value
        // then
        #expect(harness.repository.state(for: harness.request())?.id == original.id)
        #expect(harness.repository.state(for: harness.request())?.outcome == .launched(taskID: "accepted"))
    }

    @Test func givenChangedSelectionBeforeLaunch_whenStartRequested_thenNoCommandAndExplicitRefusal() async {
        // given
        let harness = ContinuationHarness()
        harness.selected.mutate { $0 = CtlClient(executable: "/fixture/replacement/ctl", environment: [:]) }
        // when
        let result = await harness.repository.start(harness.request())
        // then
        #expect(result == .refused(.qualification(.runtimeChanged)))
        #expect(harness.repository.state(for: harness.request()) == nil)
        #expect(await harness.runner.commands.isEmpty)
    }

    @Test func givenNullRepository_whenCalled_thenUnavailableAndInitialPulseAreSafe() async {
        // given
        let repository = NullTaskContinuationRepository()
        let harness = ContinuationHarness()
        let count = LockedBox(0)
        let subscription = repository.changesPublisher().sink { count.mutate { $0 += 1 } }
        // when
        let result = await repository.start(harness.request())
        await repository.check(attemptID: UUID())
        // then
        #expect(result == .refused(.unavailable))
        #expect(repository.state(for: harness.request()) == nil)
        #expect(count.value == 1)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenReentrantSubscriber_whenStatesChange_thenQueriesDoNotDeadlockAndDuplicatesStayQuiet() async {
        // given
        let harness = ContinuationHarness()
        let states = LockedBox<[TaskContinuationAttempt?]>([])
        let subscription = harness.repository.changesPublisher().sink {
            let current = harness.repository.state(for: harness.request())
            states.mutate { $0.append(current) }
        }
        // when
        _ = await harness.repository.start(harness.request())
        _ = await harness.repository.start(harness.request())
        await harness.repository.check(attemptID: UUID())
        // then
        #expect(states.value.count == 3)
        #expect(states.value.first! == nil)
        #expect(states.value.last??.outcome == .launched(taskID: "accepted"))
        withExtendedLifetime(subscription) {}
    }
}
