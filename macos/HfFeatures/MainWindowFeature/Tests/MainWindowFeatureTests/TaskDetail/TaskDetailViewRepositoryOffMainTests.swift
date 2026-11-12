import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
}

/// Subscribes with a `nonisolated` sink so the test's own closure never carries main-actor isolation.
private struct Subscription: @unchecked Sendable {
    let sut: TaskDetailViewRepository
    let cancellable: AnyCancellable
}

/// Deliberately not `@MainActor`: the real snapshot repository publishes from background contexts,
/// and a main-actor suite would send on the main thread and hide an isolation trap.
@Suite struct TaskDetailViewRepositoryOffMainTests {

    private static func subscribe(
        _ publisher: AnyPublisher<Void, Never>,
        counter: Counter
    ) -> AnyCancellable {
        publisher.sink { @Sendable in counter.increment() }
    }

    @Test func givenRealSnapshotRepository_whenChangesAreSentOffMain_thenStatusReadPublisherDelivers() async {
        // given
        let snapshots = TaskSnapshotRepositoryImpl(toolEnvironment: NullToolEnvironmentRepository())
        let counter = Counter()
        let subscription = await MainActor.run {
            let sut = TaskDetailViewRepository(taskSnapshotRepository: snapshots)
            return Subscription(sut: sut, cancellable: Self.subscribe(sut.statusReadChangesPublisher(), counter: counter))
        }
        #expect(counter.value == 1) // prepended initial emission

        // when: eviction sent from a detached, non-main task
        await Task.detached { snapshots.evict(keeping: []) }.value

        // then
        await waitUntil { counter.value >= 2 }
        #expect(counter.value == 2)

        // when: a refresh completion sent from a detached, non-main task
        await Task.detached { await snapshots.refresh("offmain") }.value

        // then
        await waitUntil { counter.value >= 3 }
        #expect(counter.value == 3)
        withExtendedLifetime(subscription) {}
    }
}
