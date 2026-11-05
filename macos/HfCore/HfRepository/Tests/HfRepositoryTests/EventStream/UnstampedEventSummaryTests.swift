import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - UnstampedEventSummaryTests

@Suite struct UnstampedEventSummaryTests {
    @Test func givenPublicCapabilityRefusal_whenObserved_thenHistoryUnavailableIsDistinctFromEmptyCapturedHistory() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        #expect(sut.eventsAvailability(for: "task") == .loading)
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        // when
        harness.reader.finish(0, .failure(.refused(code: "missing_capability", message: "public task events unsupported")))
        await waitUntil { sut.observation(for: "task").history.currentness == .reconnecting }
        // then
        let frame = sut.observation(for: "task")
        #expect(frame.records.isEmpty)
        #expect(frame.history.reasons.contains(.unavailable))
        #expect(frame.history.availableActions == [.retryRead])
        #expect(frame.summary.counts == nil)
        #expect(sut.eventsAvailability(for: "task") == .unavailable)
        #expect(sut.requestState(for: "task") == .notRequested)
    }
}
