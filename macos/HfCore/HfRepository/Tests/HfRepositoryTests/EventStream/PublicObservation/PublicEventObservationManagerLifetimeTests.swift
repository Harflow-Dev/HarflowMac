import Foundation
@testable import HfRepository
import HfTestUtilities
import Testing

// MARK: - PublicEventObservationManagerLifetimeTests

@Suite struct PublicEventObservationManagerLifetimeTests {
    @Test func givenRetainedLease_whenManagerIsDestroyed_thenItsSessionStops() async throws {
        // given
        let reader = ObservationScriptReader()
        var manager: PublicEventObservationManager? = PublicEventObservationManager(scheduler: NullScheduling(), delivery: { $0() })
        let lease = try #require(manager?.acquire(taskID: "task", reader: reader) { _ in })
        await waitUntil { reader.requests.count == 1 }
        // when
        manager = nil
        // then
        #expect(lease.session.snapshot.stopped)
        #expect(!reader.requests[0].isCurrent())
        reader.finish(0, .success(ObservationFixtures.page()))
        lease.release()
    }
}
