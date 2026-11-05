import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - PublicEventFacadeMailboxTests

@Suite struct PublicEventFacadeMailboxTests {
    @Test func givenMainDeliveryParked_whenManyActivitySummaryAndRequestRevisionsArrive_thenOnePendingCallbackPublishesOnlyLatestFacts() async {
        // given
        let mailbox = ObservationMailbox()
        let harness = PublicEventFacadeHarness(publicationDelivery: mailbox.enqueue)
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        let frames = LockedBox<[EventObservationFrame]>([])
        let requests = LockedBox<[TaskRequestReadState]>([])
        let frameSubscription = sut.observationPublisher(for: "task").sink { frame in frames.mutate { $0.append(frame) } }
        let requestSubscription = sut.requestPublisher(for: "task").sink { request in requests.mutate { $0.append(request) } }
        defer { frameSubscription.cancel(); requestSubscription.cancel() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "call-1", path: "file-1")], newer: "cursor-1")))
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .success(ObservationFixtures.page(newer: "cursor-1")))
        await waitUntil { sut.observation(for: "task").summary.counts?.toolCalls == 1 }
        // when — the main delivery seam stays parked for all revisions.
        for seq in 2 ... 21 {
            harness.tick()
            let liveIndex = (seq - 1) * 2
            await waitUntil { harness.reader.requests.count == liveIndex + 1 }
            let call = ObservationFixtures.call(seq, id: "call-\(seq)", path: "file-\(seq)")
            harness.reader.finish(liveIndex, .success(ObservationFixtures.page([call], newer: "cursor-\(seq)")))
            await waitUntil { harness.reader.requests.count == liveIndex + 2 }
            harness.reader.finish(liveIndex + 1, .success(ObservationFixtures.page([call], newer: "cursor-\(seq)")))
            await waitUntil { sut.observation(for: "task").summary.counts?.toolCalls == seq }
            #expect(sut.observation(for: "task").records.count == seq)
            #expect(mailbox.pendingCount == 1)
        }
        for index in 0 ..< 3 {
            sut.readRequest(for: "task", maxBytes: 65536)
            await waitUntil { harness.prompts.requests.count == index + 1 }
            let failure = ToolError.refused(code: "unavailable", message: "request failure \(index)")
            harness.prompts.finish(index, .failure(failure))
            await waitUntil { sut.requestState(for: "task") == .failed(failure, maxBytes: 65536) }
            #expect(mailbox.pendingCount == 1)
        }
        let latestFrame = sut.observation(for: "task")
        let latestRequest = sut.requestState(for: "task")
        // then
        let noPublishedRecords = frames.value.allSatisfy(\.records.isEmpty)
        #expect(noPublishedRecords)
        #expect(requests.value.allSatisfy { $0 == .notRequested })
        mailbox.flush()
        await waitUntil { frames.value.last == latestFrame && requests.value.last == latestRequest }
        #expect(frames.value.filter { !$0.records.isEmpty } == [latestFrame])
        #expect(requests.value.filter { $0 != .notRequested } == [latestRequest])
        #expect(mailbox.pendingCount == 0)
    }

    @Test func givenPublicationParked_whenRuntimeReplacesSource_thenOnlyReplacementFrameCanEscape() async {
        // given
        let mailbox = ObservationMailbox()
        let harness = PublicEventFacadeHarness(publicationDelivery: mailbox.enqueue)
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        let frames = LockedBox<[EventObservationFrame]>([])
        let subscription = sut.observationPublisher(for: "task").sink { frame in frames.mutate { $0.append(frame) } }
        defer { subscription.cancel() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").records.count == 1 }
        let oldScope = sut.observation(for: "task").scope
        // when
        sut.invalidateRuntime()
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.record(2)], capture: "future_capture")))
        await waitUntil { sut.events(for: "task").map(\.seq) == [2] }
        #expect(mailbox.pendingCount == 1)
        mailbox.flush()
        await waitUntil { frames.value.last?.events.map(\.seq) == [2] }
        // then
        #expect(sut.observation(for: "task").scope != oldScope)
        #expect(frames.value.allSatisfy { $0.records.isEmpty || $0.events.map(\.seq) == [2] })
        #expect(mailbox.pendingCount == 0)
    }

    @Test func givenPublicationAndRequestParked_whenFinalRoleReleases_thenOnlyClearedFactsCanEscape() async {
        // given
        let mailbox = ObservationMailbox()
        let harness = PublicEventFacadeHarness(publicationDelivery: mailbox.enqueue)
        let sut = harness.repository
        let lease = sut.acquire("task")
        let frames = LockedBox<[EventObservationFrame]>([])
        let requests = LockedBox<[TaskRequestReadState]>([])
        let frameSubscription = sut.observationPublisher(for: "task").sink { frame in frames.mutate { $0.append(frame) } }
        let requestSubscription = sut.requestPublisher(for: "task").sink { request in requests.mutate { $0.append(request) } }
        defer { frameSubscription.cancel(); requestSubscription.cancel() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").records.count == 1 }
        sut.readRequest(for: "task", maxBytes: 65536)
        await waitUntil { harness.prompts.requests.count == 1 }
        // when
        lease.release()
        #expect(!harness.prompts.requests[0].current())
        harness.prompts.finish(0, .failure(.refused(code: "late", message: "obsolete")))
        #expect(mailbox.pendingCount == 1)
        mailbox.flush()
        await waitUntil { !frames.value.isEmpty && !requests.value.isEmpty }
        // then
        #expect(sut.observation(for: "task").records.isEmpty)
        #expect(sut.requestState(for: "task") == .notRequested)
        let noPublishedRecords = frames.value.allSatisfy(\.records.isEmpty)
        #expect(noPublishedRecords)
        #expect(requests.value.allSatisfy { $0 == .notRequested })
        #expect(mailbox.pendingCount == 0)
    }
}
