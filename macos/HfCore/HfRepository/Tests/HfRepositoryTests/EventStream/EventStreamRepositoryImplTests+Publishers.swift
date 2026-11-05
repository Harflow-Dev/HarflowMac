import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

extension EventStreamRepositoryImplTests {
    @Test func givenOverlappingOlderDemands_whenOnePageCompletes_thenItemsArePresentBeforeCompletedHistoryPublishes() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(2)], older: "earlier", capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").records.count == 1 }
        let completed = LockedBox<[Int]>([])
        let subscription = sut.historyPublisher(for: "task").sink { history in
            if !history.isLoading { completed.mutate { $0.append(sut.items(for: "task").count) } }
        }
        defer { subscription.cancel() }
        await waitUntil { completed.value == [1] }
        // when
        for _ in 0 ..< 20 { sut.loadMore("task") }
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.record(1)])))
        await waitUntil { completed.value.last == 2 }
        // then
        #expect(harness.reader.requests[1].position == .cursor("earlier"))
        #expect(sut.events(for: "task").map(\.seq) == [1, 2])
        #expect(harness.reader.requests.count == 2)
        #expect(completed.value == [1, 2])
    }

    @Test func givenOlderPageParkedWithContinuation_whenTwentyDemandsOverlap_thenOnlyFreshPostCompletionActionLoadsNextPage() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(3)], older: "page-A", capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").records.count == 1 }
        let loading = LockedBox<[Bool]>([])
        let completedCounts = LockedBox<[Int]>([])
        let subscription = sut.historyPublisher(for: "task").sink { history in
            loading.mutate { $0.append(history.isLoading) }
            if !history.isLoading { completedCounts.mutate { $0.append(sut.items(for: "task").count) } }
        }
        defer { subscription.cancel() }
        await waitUntil { completedCounts.value == [1] }
        // when — page A remains parked, and genuinely has another historical page behind it.
        #expect(sut.loadMore("task"))
        await waitUntil { harness.reader.requests.count == 2 && loading.value.last == true }
        #expect(harness.reader.requests[1].position == .cursor("page-A"))
        #expect(!sut.observation(for: "task").history.availableActions.contains(.loadEarlier))
        for _ in 0 ..< 20 { #expect(!sut.loadMore("task")) }
        harness.reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.record(2)], older: "page-B")))
        await waitUntil { completedCounts.value == [1, 2] }
        // then — completion publishes admitted items first and has no queued second demand.
        #expect(loading.value == [false, true, false])
        #expect(sut.events(for: "task").map(\.seq) == [2, 3])
        #expect(harness.reader.requests.count == 2)
        #expect(sut.observation(for: "task").history.availableActions.contains(.loadEarlier))
        #expect(sut.loadMore("task"))
        await waitUntil { harness.reader.requests.count == 3 && loading.value.last == true }
        #expect(harness.reader.requests[2].position == .cursor("page-B"))
        harness.reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(1)])))
        await waitUntil { completedCounts.value == [1, 2, 3] }
        #expect(loading.value == [false, true, false, true, false])
        #expect(sut.events(for: "task").map(\.seq) == [1, 2, 3])
        #expect(harness.reader.requests.count == 3)
    }

    @Test func givenUnchangedPublicPolls_whenAnotherChangedPageCompletes_thenOnlyChangedItemsPublish() async {
        // given
        let deliveries = LockedBox(0)
        let harness = PublicEventFacadeHarness(delivery: { body in
            body()
            deliveries.mutate { $0 += 1 }
        })
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], newer: "same", capture: "future_capture")))
        await waitUntil { sut.items(for: "task").count == 1 }
        let values = LockedBox<[[TimelineItem]]>([])
        let subscription = sut.itemsPublisher(for: "task").sink { value in values.mutate { $0.append(value) } }
        defer { subscription.cancel() }
        await waitUntil { values.value.count == 1 }
        // when
        harness.tick()
        await waitUntil { harness.reader.requests.count == 2 }
        let beforeCompletion = deliveries.value
        harness.reader.finish(1, .success(ObservationFixtures.page(newer: "same")))
        await waitUntil { deliveries.value > beforeCompletion }
        harness.tick()
        await waitUntil { harness.reader.requests.count == 3 }
        harness.reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(2)], newer: "changed")))
        await waitUntil { values.value.last?.count == 2 }
        // then
        #expect(values.value.count == 2)
        #expect(values.value.last == sut.items(for: "task"))
        #expect(sut.items(for: "task") == Timeline.items(from: sut.events(for: "task")))
    }

    @Test func givenOldQueuedPublication_whenRuntimeInvalidates_thenSubscriberReceivesOnlyCurrentScope() async {
        // given
        let mailbox = ObservationMailbox()
        let harness = PublicEventFacadeHarness(delivery: mailbox.enqueue)
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        let received = LockedBox<[EventObservationFrame]>([])
        let subscription = sut.observationPublisher(for: "task").sink { value in received.mutate { $0.append(value) } }
        defer { subscription.cancel() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], capture: "future_capture")))
        // when
        sut.invalidateRuntime()
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.record(2)], capture: "future_capture")))
        await waitUntil { mailbox.pendingCount >= 2 }
        mailbox.flush()
        await waitUntil { sut.events(for: "task").map(\.seq) == [2] }
        await waitUntil { received.value.last?.events.map(\.seq) == [2] }
        // then
        #expect(received.value.allSatisfy { !$0.records.contains { $0.record.seq == 1 } })
        #expect(!harness.reader.requests[0].isCurrent())
    }

    @Test func givenOneForwardPageWithDeltasAndTerminal_whenDelivered_thenOneAtomicFrameIncludesAllRowsAndFinality() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page(newer: "cursor", capture: "future_capture")))
        await waitUntil { !sut.observation(for: "task").history.isLoading }
        // when
        harness.tick()
        await waitUntil { harness.reader.requests.count == 2 }
        let delta = ObservationFixtures.record(1, "assistant_delta", ["text": .string("chunk"), "message_id": .string("m"), "block_index": .number(0)])
        let final = ObservationFixtures.record(2, "task_finished", ["status": .string("completed")])
        harness.reader.finish(1, .success(ObservationFixtures.page([delta, final], newer: "final", final: 2)))
        await waitUntil { sut.observation(for: "task").history.forwardDrained }
        // then
        let frame = sut.observation(for: "task")
        #expect(frame.records.map(\.record.seq) == [1, 2])
        #expect(frame.items.count == 2)
        #expect(frame.items.contains { if case .text(let text, _) = $0.body { return text == "chunk" }; return false })
        #expect(frame.items.contains { if case .finished = $0.body { return true }; return false })
        #expect(frame.summary.counts == nil)
    }
}
