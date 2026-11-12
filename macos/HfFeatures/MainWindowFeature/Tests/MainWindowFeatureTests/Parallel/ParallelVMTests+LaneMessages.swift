import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - ParallelVM lane messaging

@MainActor
extension ParallelVMTests {
    @Test func givenASettledLane_whenALaneSubmitQueuesAMessage_thenItIsAcceptedAndQueuedExactlyOnce() async throws {
        // given
        let harness = makeSUT()
        let settled = task(id: "done", status: "completed")
        harness.tasksBox.value = ["done": settled]
        given(harness.useCase).sendMessage(.any, text: .any, now: .any).willReturn([:])
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([settled])
        await waitUntil { harness.sut.columns.count == 1 }
        let column = try #require(harness.sut.columns.first)

        // when — the lane composer only ever queues (`now: false`)
        #expect(column.onSubmitMessage?("follow up", false) == true)

        // then
        await verify(harness.useCase)
.sendMessage(.value("done"), text: .value("follow up"), now: .value(false))
            .calledEventually(1, before: .seconds(5))
        verify(harness.useCase).sendMessage(.any, text: .any, now: .value(true)).called(0)
    }

    @Test func givenALaneOutcome_whenItChanges_thenTheColumnCarriesItForTheFeedTail() async {
        // given
        let harness = makeSUT()
        let current = task(id: "current")
        harness.tasksBox.value = ["current": current]
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([current])
        await waitUntil { harness.sut.columns.count == 1 }

        // when
        harness.outcomesSubject.send(["current": "Queued message cancelled."])

        // then
        await waitUntil { harness.sut.columns.first?.outcomeMessage == "Queued message cancelled." }
        #expect(harness.sut.columns.first?.outcomeMessage == "Queued message cancelled.")
    }
}
