import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PendingLaunchStopTests

@Suite struct PendingLaunchStopTests {
    private func ready(_ harness: PendingLaunchHarness) async throws -> (PendingLaunchReadLease, PendingLaunchSelection, PendingLaunchStopConfirmation) {
        let lease = try #require(harness.owner.acquireReadLease())
        await waitUntil { harness.owner.snapshot.inventory.completedCheck }
        let selection = try #require(harness.owner.bindSelection(taskID: "target", lease: lease))
        guard case .confirmation(let confirmation) = await harness.owner.prepareStop(selection: selection) else {
            throw QualificationSessionError.missingIdentity
        }
        return (lease, selection, confirmation)
    }

    @Test func givenConfirmation_whenSubmittedTwice_thenOneOwnerAttemptDispatches() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        // when
        guard case .submitted(let id) = harness.owner.submitStop(confirmation: confirmation) else { Issue.record("not submitted"); return }
        #expect(harness.owner.submitStop(confirmation: confirmation) == .existing(id))
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        // then
        #expect(await harness.runner.calls.filter { $0.first == "cancel" }.count == 1)
        #expect(harness.owner.snapshot.attempts[0].outcome != nil)
    }

    @Test func givenSubmittedStop_whenViewDisappearsDuringPreflight_thenConfirmedOwnerFinishes() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (lease, _, confirmation) = try await ready(harness)
        let latch = ContinuationLatch()
        await harness.runner.setLatch(latch)
        _ = harness.owner.submitStop(confirmation: confirmation)
        await latch.waitForArrival()
        // when
        harness.owner.releaseReadLease(lease)
        await latch.release()
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        // then
        #expect(await harness.runner.calls.filter { $0.first == "cancel" }.count == 1)
    }

    @Test func givenRecordedPreflight_whenConfirmedStopSubmitted_thenNoPendingCancelIsDispatched() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        await harness.runner.setLookups([pendingEnvelope(pendingLookup(disposition: "recorded"))])
        // when
        _ = harness.owner.submitStop(confirmation: confirmation)
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        // then
        #expect(harness.owner.snapshot.attempts[0].preflightFailure == .recorded)
        #expect(await harness.runner.calls.allSatisfy { $0.first != "cancel" })
    }

    @Test func givenGenerationChangesDuringConfirmation_whenSubmitted_thenNoCancelIsDispatched() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        await harness.runner.setLookups([pendingEnvelope(pendingLookup(generation: String(repeating: "c", count: 32)))])
        // when
        _ = harness.owner.submitStop(confirmation: confirmation)
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        // then
        #expect(harness.owner.snapshot.attempts[0].preflightFailure == .changed)
        #expect(await harness.runner.calls.allSatisfy { $0.first != "cancel" })
    }

    @Test func givenGenericTaskBusy_whenSubmitted_thenNoPendingCommandIsDispatched() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        #expect(harness.actions.tryBeginBusy("target"))
        // when
        _ = harness.owner.submitStop(confirmation: confirmation)
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        // then
        #expect(harness.owner.snapshot.attempts[0].preflightFailure == .busy)
        #expect(harness.actions.busy.contains("target"))
        harness.actions.endBusy("target")
    }

    @Test func givenRuntimeChangedAfterConfirmation_whenSubmitted_thenOldTokenRefuses() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        // when
        harness.owner.runtimeChanged()
        // then
        #expect(harness.owner.submitStop(confirmation: confirmation) == .refused(.changed))
        #expect(harness.owner.snapshot.attempts.isEmpty)
    }

    @Test func givenEngineErrorAfterDispatch_whenRuntimeChanges_thenUnsafeEvidenceAndReasonSurvive() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        await harness.runner.setCancel(pendingEnvelope([:], error: "could_have_effect"))
        // when
        _ = harness.owner.submitStop(confirmation: confirmation)
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        harness.owner.runtimeChanged()
        // then
        guard case .engineError(_, let error)? = harness.owner.snapshot.attempts[0].outcome else { Issue.record("engine error lost"); return }
        #expect(error.message == "could_have_effect")
        #expect(!harness.actions.busy.contains("target"))
    }

    @Test func givenNotStartedOrFutureState_whenPrepared_thenNoConfirmationAuthority() async throws {
        for state in ["not_started", "future_state"] {
            // given
            let harness = PendingLaunchHarness(runner: PendingLaunchRunner(lookups: [pendingEnvelope(pendingLookup(state: state))]))
            let lease = try #require(harness.owner.acquireReadLease())
            await waitUntil { harness.owner.snapshot.inventory.completedCheck }
            let selection = try #require(harness.owner.bindSelection(taskID: "target", lease: lease))
            // when / then
            #expect(await harness.owner.prepareStop(selection: selection) == .failed(.unsupported))
        }
    }

    @Test func givenUnstructuredLargeDiagnostic_whenRetained_thenTruncationIsExplicitAndUncertaintyPreserved() throws {
        // given
        let request = try #require(TaskPendingLaunchStopRequest(taskID: "target"))
        let outcome: TaskPendingLaunchStopOutcome = .uncertain(request, cause: .unreadableOutput(exitCode: 0, stderr: String(repeating: "x", count: 20000)))
        // when
        let retained = PendingLaunchRepositoryImpl.boundedOutcome(outcome)
        // then
        #expect(retained.1)
        guard case .uncertain(_, .unreadableOutput(_, let diagnostic)) = retained.0 else { Issue.record("uncertainty erased"); return }
        #expect(diagnostic.hasSuffix("[diagnostic truncated]") && diagnostic.utf8.count < 9000)
    }

    @Test(arguments: ["proven_not_started", "observed_settlement"])
    func givenQualifiedStopObservation_whenRetained_thenNeverStartedIsSeparateFromSettlement(basis: String) async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        await harness.runner.setCancel(pendingEnvelope(pendingCancelResult(basis: basis)))
        // when
        _ = harness.owner.submitStop(confirmation: confirmation)
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        // then
        guard case .accepted(let receipt)? = harness.owner.snapshot.attempts[0].outcome else { Issue.record("Missing receipt"); return }
        #expect(receipt.targetIsProvenStopped)
        #expect(receipt.targetIsProvenNotStarted == (basis == "proven_not_started"))
    }

    @Test func givenCancelCapabilityMissingAfterConfirmation_whenSubmitted_thenPairedHandshakePreventsDispatch() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        await harness.runner.setCapabilities(["ctl.v1", "setup.v1", "events.v1", "task-pending-launch.v1"])
        // when
        _ = harness.owner.submitStop(confirmation: confirmation)
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        // then
        guard case .notDispatched(_, .missingCapability)? = harness.owner.snapshot.attempts[0].outcome else {
            Issue.record("Missing paired capability did not refuse before dispatch"); return
        }
        #expect(await harness.runner.calls.allSatisfy { $0.first != "cancel" })
    }

    @Test func givenCancelAlreadyDispatched_whenRuntimeChanges_thenInvocationEvidenceStillFinishes() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, _, confirmation) = try await ready(harness)
        await harness.runner.setCancel(pendingEnvelope(pendingCancelResult(basis: "observed_settlement")))
        let latch = ContinuationLatch()
        await harness.runner.setLatch(latch, command: "cancel")
        _ = harness.owner.submitStop(confirmation: confirmation)
        await latch.waitForArrival()
        // when
        harness.owner.runtimeChanged()
        await latch.release()
        await waitUntil { !harness.owner.snapshot.attempts[0].isExecuting }
        // then
        #expect(harness.owner.snapshot.attempts[0].outcome != nil)
        #expect(harness.owner.snapshot.attempts[0].preflightFailure == nil)
        #expect(!harness.actions.busy.contains("target"))
    }

}
