import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - Lane messaging: refusals and failures

@MainActor
extension ParallelVMTests {
    @Test func givenATakenOverLane_whenALaneSubmitQueues_thenItIsRefusedAndNothingIsSent() async throws {
        // given
        let harness = makeSUT()
        var raw = task(id: "taken", status: "cancelled").raw
        raw["taken_over"] = .bool(true)
        let taken = try #require(TaskInfo(.object(raw)))
        harness.tasksBox.value[taken.taskID] = taken
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([taken])
        await waitUntil { harness.sut.columns.count == 1 }

        // when / then — the lane composer queues only (`now: false`), and a taken-over lane refuses it
        #expect(harness.sut.columns.first?.onSubmitMessage?("keep", false) == false)
        verify(harness.useCase).sendMessage(.any, text: .any, now: .any).called(0)
    }

    @Test func givenALaneSendThatFails_whenItQueues_thenTheLanesOutcomeSaysSo() async throws {
        // given
        let harness = makeSUT()
        let current = task(id: "current")
        harness.tasksBox.value[current.taskID] = current
        let failure = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "send", detail: "Missing capability messaging.v1")
        given(harness.useCase).sendMessage(.any, text: .any, now: .any).willThrow(failure)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([current])
        await waitUntil { harness.sut.columns.count == 1 }

        // when
        #expect(harness.sut.columns.first?.onSubmitMessage?("check", false) == true)

        // then
        await verify(harness.useCase)
            .setOutcome(.value("current"), .value("Couldn't send the message: \(failure.message)"))
            .calledEventually(1, before: .seconds(5))
    }
}
