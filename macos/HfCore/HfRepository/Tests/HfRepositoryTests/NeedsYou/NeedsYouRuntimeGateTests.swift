import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import Testing

// MARK: - NeedsYouRuntimeGateTests

@Suite struct NeedsYouRuntimeGateTests {
    @Test func givenRuntimeNotReady_whenLoopStarts_thenNoEngineCallsUntilItBecomesReady() async {
        // given
        let state = CurrentValueSubject<RuntimeSetupState, Never>(.checking)
        let fake = FakeNeedsYouEngine()
        let scheduler = CapturingScheduler()
        let sut = makeSUT(fake, scheduler: scheduler, install: readyInstall(state))
        // when
        sut.start()
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        // then
        #expect(fake.calls.isEmpty)
        // when the runtime qualifies
        state.send(.ready)
        await waitUntil { !fake.calls.isEmpty }
        #expect(!fake.calls.isEmpty)
    }
}
