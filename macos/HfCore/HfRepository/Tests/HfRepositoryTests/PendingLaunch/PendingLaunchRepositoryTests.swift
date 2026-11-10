import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PendingLaunchRepositoryTests

@Suite struct PendingLaunchRepositoryTests {
    private func selected(_ harness: PendingLaunchHarness) async throws -> (PendingLaunchReadLease, PendingLaunchSelection) {
        let lease = try #require(harness.owner.acquireReadLease())
        await waitUntil { harness.owner.snapshot.inventory.completedCheck }
        return (lease, try #require(harness.owner.bindSelection(taskID: "target", lease: lease)))
    }

    @Test func givenNoVisibleLease_whenConstructed_thenNoNamespaceReadStarts() async {
        // given
        let harness = PendingLaunchHarness()
        // when
        let calls = await harness.runner.calls
        // then
        #expect(calls.isEmpty)
        #expect(!harness.owner.snapshot.inventory.completedCheck)
    }

    @Test func givenVisibleLease_whenAcquired_thenInitialCompleteEmptyReadIsExplicit() async throws {
        // given
        let harness = PendingLaunchHarness()
        // when
        let (lease, _) = try await selected(harness)
        // then
        #expect(harness.owner.snapshot.inventory.rows.isEmpty)
        #expect(harness.owner.snapshot.inventory.completedCheck)
        #expect(await harness.runner.calls.filter { $0.first == "task-pending-page" }.count == 1)
        harness.owner.releaseReadLease(lease)
    }

    @Test func givenEightVisibleLeases_whenNinthAcquired_thenCapacityRefusesWithoutEviction() {
        // given
        let harness = PendingLaunchHarness()
        // when
        let leases = (0 ..< 8).compactMap { _ in harness.owner.acquireReadLease() }
        // then
        #expect(leases.count == 8)
        #expect(harness.owner.acquireReadLease() == nil)
        leases.forEach(harness.owner.releaseReadLease)
    }

    @Test func givenDelayedLookup_whenSelectionChanges_thenOldLookupCannotPublishAndInventoryLeaseSurvives() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (lease, selection) = try await selected(harness)
        let latch = ContinuationLatch()
        await harness.runner.setLatch(latch)
        let task = Task { await harness.owner.check(selection: selection) }
        await latch.waitForArrival()
        // when
        let replacement = harness.owner.bindSelection(taskID: "other", lease: lease)
        await latch.release()
        let result = await task.value
        // then
        #expect(replacement != nil)
        #expect(result.failure == .superseded)
        #expect(harness.owner.snapshot.lookups.isEmpty)
        #expect(harness.owner.snapshot.inventory.completedCheck)
    }

    @Test func givenDelayedLookup_whenLeaseReleased_thenNoLateLookupIsRetained() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (lease, selection) = try await selected(harness)
        let latch = ContinuationLatch()
        await harness.runner.setLatch(latch)
        let task = Task { await harness.owner.check(selection: selection) }
        await latch.waitForArrival()
        // when
        harness.owner.releaseReadLease(lease)
        await latch.release()
        // then
        #expect(await task.value.failure == .superseded)
        #expect(harness.owner.snapshot.lookups.isEmpty)
    }

    @Test func givenDelayedLookup_whenRuntimeChangesAwayAndBack_thenOldEpochCannotBecomeFreshAgain() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, selection) = try await selected(harness)
        let firstIdentity = harness.owner.snapshot.runtimeIdentity
        let latch = ContinuationLatch()
        await harness.runner.setLatch(latch)
        let task = Task { await harness.owner.check(selection: selection) }
        await latch.waitForArrival()
        // when
        harness.owner.runtimeChanged()
        harness.owner.runtimeChanged()
        await latch.release()
        // then
        #expect(await task.value.failure == .superseded)
        #expect(harness.owner.snapshot.runtimeIdentity != firstIdentity)
        #expect(harness.owner.snapshot.lookups.isEmpty)
    }

    @Test func givenRecordedLookup_whenChecked_thenNoOrdinaryStatusOrHistoryAdmissionIsImplicit() async throws {
        // given
        let runner = PendingLaunchRunner(lookups: [pendingEnvelope(pendingLookup(disposition: "recorded"))])
        let harness = PendingLaunchHarness(runner: runner)
        let (_, selection) = try await selected(harness)
        // when
        let result = await harness.owner.check(selection: selection)
        // then
        #expect(result.value?.item.disposition == .recorded)
        #expect(await runner.calls.allSatisfy { $0.first != "status" })
    }

    @Test func givenHealthyInventory_whenRefreshFails_thenRowsRemainVisiblyStale() async throws {
        // given
        let runner = PendingLaunchRunner(pages: [pendingEnvelope(pendingPage(["target"]))])
        let harness = PendingLaunchHarness(runner: runner)
        let (lease, _) = try await selected(harness)
        await runner.setPages([pendingEnvelope([:], error: "denied")])
        // when
        await harness.owner.refresh(lease: lease)
        // then
        #expect(harness.owner.snapshot.inventory.rows.map(\.taskID) == ["target"])
        #expect(harness.owner.snapshot.inventory.isStale)
        #expect(!harness.owner.snapshot.inventory.completedCheck)
    }

    @Test func givenHealthyInventory_whenFutureStateArrives_thenHealthyMetadataRemainsAndCompletenessIsUncertain() async throws {
        // given
        let runner = PendingLaunchRunner(pages: [pendingEnvelope(pendingPage(["target"]))])
        let harness = PendingLaunchHarness(runner: runner)
        let (lease, _) = try await selected(harness)
        let future = pendingPage(overrides: ["items": .array([.object(pendingItem(state: "future"))]), "examined_count": .number(1)])
        await runner.setPages([pendingEnvelope(future)])
        // when
        await harness.owner.refresh(lease: lease)
        // then
        #expect(harness.owner.snapshot.inventory.rows.first?.launch?.state == .waitingForResources)
        #expect(harness.owner.snapshot.inventory.isStale)
        #expect(!harness.owner.snapshot.inventory.completedCheck)
    }

    @Test func givenStaleInventory_whenFreshCompleteEmptyTraversalSucceeds_thenOnlyInventoryRowsAreReplaced() async throws {
        // given
        let runner = PendingLaunchRunner(pages: [pendingEnvelope(pendingPage(["target"]))])
        let harness = PendingLaunchHarness(runner: runner)
        let (lease, selection) = try await selected(harness)
        _ = await harness.owner.check(selection: selection)
        await runner.setPages([pendingEnvelope(pendingPage())])
        // when
        await harness.owner.refresh(lease: lease)
        // then
        #expect(harness.owner.snapshot.inventory.rows.isEmpty)
        #expect(harness.owner.snapshot.lookups.count == 1)
    }

    @Test func givenEqualPublishedSnapshot_whenPublicationIsRepeated_thenRenderingPublisherStaysQuiet() {
        // given
        let harness = PendingLaunchHarness()
        let values = LockedBox(0)
        let subscription = harness.owner.snapshotPublisher().sink { _ in values.mutate { $0 += 1 } }
        // when
        harness.owner.publish()
        harness.owner.publish()
        let first = values.value
        harness.owner.publish()
        // then
        #expect(values.value == first)
        withExtendedLifetime(subscription) {}
    }

    @Test func givenNullOwner_whenReadInterestRequested_thenUnavailableNeverLooksComplete() {
        // given
        let owner = NullPendingLaunchRepository()
        // when / then
        #expect(owner.acquireReadLease() == nil)
        #expect(owner.snapshot.inventory.failure == .unavailable)
        #expect(!owner.snapshot.inventory.completedCheck)
    }

    @Test func givenDelayedCapabilityProbe_whenSelectionRevoked_thenPendingCommandNeverDispatches() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (lease, selection) = try await selected(harness)
        let latch = ContinuationLatch()
        await harness.runner.setProbeLatch(latch)
        let task = Task { await harness.owner.check(selection: selection) }
        await latch.waitForArrival()
        // when
        _ = harness.owner.bindSelection(taskID: nil, lease: lease)
        await latch.release()
        // then
        #expect(await task.value.failure == .superseded)
        #expect(await harness.runner.calls.allSatisfy { $0.first != "task-pending-status" })
    }

    @Test func givenStoredLookups_whenOneLeaseReleased_thenOnlyItsLookupsAreRemovedAndLaterLeasesCanStore() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (first, firstSelection) = try await selected(harness)
        let second = try #require(harness.owner.acquireReadLease())
        let secondSelection = try #require(harness.owner.bindSelection(taskID: "target", lease: second))
        _ = await harness.owner.check(selection: firstSelection)
        _ = await harness.owner.check(selection: secondSelection)
        #expect(harness.owner.snapshot.lookups.count == 2)
        // when
        harness.owner.releaseReadLease(first)
        // then
        #expect(harness.owner.snapshot.lookups.map(\.selection.lease) == [second])
        for _ in 0 ..< 130 {
            let lease = try #require(harness.owner.acquireReadLease())
            let selection = try #require(harness.owner.bindSelection(taskID: "target", lease: lease))
            let result = await harness.owner.check(selection: selection)
            #expect(result.failure == nil)
            harness.owner.releaseReadLease(lease)
        }
        #expect(harness.owner.snapshot.lookups.map(\.selection.lease) == [second])
    }

    @Test func givenLookupAlreadyInFlight_whenCheckedAgain_thenReadAdmissionIsBoundedWithoutExtraCommand() async throws {
        // given
        let harness = PendingLaunchHarness()
        let (_, selection) = try await selected(harness)
        let latch = ContinuationLatch()
        await harness.runner.setLatch(latch)
        let first = Task { await harness.owner.check(selection: selection) }
        await latch.waitForArrival()
        // when
        let second = await harness.owner.check(selection: selection)
        // then
        #expect(second.failure == .busy)
        #expect(await harness.runner.calls.filter { $0.first == "task-pending-status" }.count == 1)
        await latch.release()
        _ = await first.value
    }

}
