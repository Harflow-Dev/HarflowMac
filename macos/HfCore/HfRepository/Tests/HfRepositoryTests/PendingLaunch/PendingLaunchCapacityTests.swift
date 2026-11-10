import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PendingLaunchCapacityTests

@Suite struct PendingLaunchCapacityTests {
    private func confirmation(_ harness: PendingLaunchHarness, selection: PendingLaunchSelection) async throws -> PendingLaunchStopConfirmation {
        guard case .confirmation(let value) = await harness.owner.prepareStop(selection: selection) else {
            throw QualificationSessionError.evidenceChanged
        }
        return value
    }

    @Test func givenTwentySmallUnsafeOutcomes_whenNewGenerationsAreConfirmed_thenUnusedWorstCaseReservationIsReleased() async throws {
        // given
        let harness = PendingLaunchHarness()
        let lease = try #require(harness.owner.acquireReadLease())
        await waitUntil { harness.owner.snapshot.inventory.completedCheck }
        let selection = try #require(harness.owner.bindSelection(taskID: "target", lease: lease))
        // when
        for index in 0 ..< 20 {
            let generation = String(format: "%032x", index)
            await harness.runner.setLookups([pendingEnvelope(pendingLookup(generation: generation))])
            let confirmation = try await confirmation(harness, selection: selection)
            guard case .submitted = harness.owner.submitStop(confirmation: confirmation) else { Issue.record("Small outcomes exhausted reservations"); return }
            await waitUntil { harness.owner.snapshot.attempts.allSatisfy { !$0.isExecuting } }
        }
        // then
        #expect(harness.owner.snapshot.attempts.count == 20)
        #expect(harness.owner.lock.withLock { harness.owner.attemptCosts.values.reduce(0, +) } < 1024 * 1024)
    }

    @Test func givenRetainedByteCapacityExhausted_whenStopConfirmed_thenRefusesBeforeDispatchAndPreservesPriorCosts() async throws {
        // given
        let harness = PendingLaunchHarness()
        let lease = try #require(harness.owner.acquireReadLease())
        await waitUntil { harness.owner.snapshot.inventory.completedCheck }
        let selection = try #require(harness.owner.bindSelection(taskID: "target", lease: lease))
        let confirmation = try await confirmation(harness, selection: selection)
        let retained = UUID()
        harness.owner.lock.withLock { harness.owner.attemptCosts[retained] = PendingLaunchRepositoryImpl.attemptByteLimit }
        // when
        let result = harness.owner.submitStop(confirmation: confirmation)
        // then
        #expect(result == .refused(.capacity))
        #expect(harness.owner.lock.withLock { harness.owner.attemptCosts[retained] } == PendingLaunchRepositoryImpl.attemptByteLimit)
        #expect(await harness.runner.calls.allSatisfy { $0.first != "cancel" })
    }

    @Test func givenConfirmationBeforeNavigation_whenSelectionClears_thenItCannotSubmitFromStaleSheet() async throws {
        // given
        let harness = PendingLaunchHarness()
        let lease = try #require(harness.owner.acquireReadLease())
        await waitUntil { harness.owner.snapshot.inventory.completedCheck }
        let selection = try #require(harness.owner.bindSelection(taskID: "target", lease: lease))
        let confirmation = try await confirmation(harness, selection: selection)
        // when
        _ = harness.owner.bindSelection(taskID: nil, lease: lease)
        // then
        #expect(harness.owner.submitStop(confirmation: confirmation) == .refused(.changed))
        #expect(harness.owner.snapshot.attempts.isEmpty)
    }

    @Test func givenInlineRuntimeNotifications_whenAwayAndBack_thenOldSelectionIsSynchronouslyRevoked() async throws {
        // given
        let harness = PendingLaunchHarness()
        let lease = try #require(harness.owner.acquireReadLease())
        await waitUntil { harness.owner.snapshot.inventory.completedCheck }
        let selection = try #require(harness.owner.bindSelection(taskID: "target", lease: lease))
        let old = harness.owner.context(selection: selection)?.1
        // when
        harness.owner.runtimeChanged()
        harness.owner.runtimeChanged()
        // then
        #expect(old?.isCurrent == false)
        #expect(harness.owner.context(selection: selection) == nil)
    }
}
