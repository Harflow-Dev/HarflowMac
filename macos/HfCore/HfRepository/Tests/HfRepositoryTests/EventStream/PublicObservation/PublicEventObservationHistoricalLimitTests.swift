import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import os
import Testing

// MARK: - PublicEventObservationHistoricalLimitTests

@Suite struct PublicEventObservationHistoricalLimitTests {
    @Test func givenPerpetualHistoricalSeek_when4096OperationsAreSpent_thenHistoryStopsButLivePollingRemainsAvailable() async {
        // given
        let reader = PerpetualHistoryReader()
        let sut = PublicEventObservationSession(taskID: "task", reader: reader, scheduler: NullScheduling(),
            budget: EventInitialLoadQueue(limit: 2), delivery: { $0() })
        defer { sut.stop() }
        sut.subscribe(id: UUID()) { _ in }
        // when
        await waitUntil(timeout: 30) { sut.snapshot.summaryPhase == .limited }
        // then
        #expect(sut.snapshot.historicalOperations == 4096)
        #expect(reader.historyReads == 4096)
        #expect(sut.snapshot.issues.contains(.historicalLimit))
        #expect(sut.snapshot.summary.counts == nil)
        let before = reader.liveReads
        sut.tick()
        await waitUntil { reader.liveReads == before + 1 }
        #expect(reader.historyReads == 4096)
        #expect(sut.snapshot.historicalOperations == 4096)
    }
}

private final class PerpetualHistoryReader: PublicEventObservationReader, Sendable {
    private struct State: Sendable { var history = 0; var live = 0 }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var historyReads: Int { state.withLock { $0.history } }
    var liveReads: Int { state.withLock { $0.live } }
    func read(taskID _: String, position: TaskEventPagePosition,
              operationIsCurrent _: @escaping @Sendable () -> Bool) async -> Result<TaskEventPage, ToolError> {
        switch position {
        case .newest: return .success(ObservationFixtures.page(older: "history-0", newer: "live"))
        case .cursor("live"):
            state.withLock { $0.live += 1 }
            return .success(ObservationFixtures.page(newer: "live"))
        case .cursor:
            let index = state.withLock { $0.history += 1; return $0.history }
            return .success(ObservationFixtures.page(older: "history-\(index)", newer: "unused"))
        case .oldest:
            Issue.record("Historical traversal must retain newest lineage")
            return .failure(.refused(code: "unexpected_oldest", message: "unexpected"))
        }
    }
}
