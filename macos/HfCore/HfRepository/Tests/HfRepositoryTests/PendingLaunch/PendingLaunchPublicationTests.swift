import Combine
import Foundation
@testable import HfRepository
import Testing

// MARK: - PendingLaunchPublicationTests

@Suite struct PendingLaunchPublicationTests {
    @Test func givenTwoListeners_whenFirstReentersWithRuntimeChange_thenBothReceiveWholeWavesInOrder() {
        // given
        let owner = PendingLaunchHarness().owner
        let first = LockedBox<[Bool]>([])
        let second = LockedBox<[Bool]>([])
        let fired = LockedBox(false)
        let one = owner.snapshotPublisher().sink { snapshot in
            first.mutate { $0.append(snapshot.inventory.completedCheck) }
            if snapshot.inventory.completedCheck, !fired.value {
                fired.mutate { $0 = true }
                owner.runtimeChanged()
            }
        }
        let two = owner.snapshotPublisher().sink { snapshot in second.mutate { $0.append(snapshot.inventory.completedCheck) } }
        // when
        owner.lock.withLock { owner.value.inventory.completedCheck = true }
        owner.publish()
        // then
        #expect(first.value == [false, true, false])
        #expect(second.value == first.value)
        withExtendedLifetime((one, two)) {}
    }

    @Test func givenSubscriberCrossThreadReentry_whenItSynchronouslyWaitsForRuntimeChange_thenNoOwnerLockBlocksTheWorker() {
        // given
        let owner = PendingLaunchHarness().owner
        let result = LockedBox(false)
        let subscription = owner.snapshotPublisher().sink { snapshot in
            guard snapshot.inventory.completedCheck else { return }
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                owner.runtimeChanged()
                done.signal()
            }
            result.mutate { $0 = done.wait(timeout: .now() + 2) == .success }
        }
        // when
        owner.lock.withLock { owner.value.inventory.completedCheck = true }
        owner.publish()
        // then
        #expect(result.value)
        #expect(!owner.snapshot.inventory.completedCheck)
        withExtendedLifetime(subscription) {}
    }
}
