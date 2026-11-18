import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - Workflow-owned composer locks

@MainActor
extension ParallelVMTests {
    private func appearWithLane(_ harness: SUT, id: String = "lane", raw extra: [String: JSONValue] = [:]) async throws -> TaskInfo {
        var raw = task(id: id, status: "cancelled").raw
        for (key, value) in extra { raw[key] = value }
        let lane = try #require(TaskInfo(.object(raw)))
        harness.tasksBox.value[id] = lane
        harness.sut.didAppear()
        harness.tasksSubject.send([lane])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        return lane
    }

    @Test func givenWorkflowLanes_whenTheRunGoesRunningThenCancellingThenCancelled_thenOnlyTheLastStepLocksWithOneRepublish() async throws {
        // given
        let harness = makeSUT()
        _ = try await appearWithLane(harness)
        defer { harness.sut.didDisappear() }
        let before = harness.sut.presentationWriteCount

        // when — the same task ids throughout, as the run settles
        harness.sut.setWorkflowRunMessageLock(false)
        harness.sut.setWorkflowRunMessageLock(false)

        // then
        #expect(harness.sut.columns.first?.messageLock == nil)
        #expect(harness.sut.presentationWriteCount == before)

        // when
        harness.sut.setWorkflowRunMessageLock(true)

        // then
        #expect(harness.sut.columns.first?.messageLock == .runCancelled)
        #expect(harness.sut.columns.first?.laneComposerLock == .runCancelled)
        #expect(harness.sut.presentationWriteCount == before + 1)

        // when — an unchanged lock republishes nothing
        harness.sut.setWorkflowRunMessageLock(true)

        // then
        #expect(harness.sut.presentationWriteCount == before + 1)
    }

    @Test func givenALockedLane_whenTheRunChangesToOneThatIsNotCancelled_thenTheLockClears() async throws {
        // given
        let harness = makeSUT()
        _ = try await appearWithLane(harness)
        defer { harness.sut.didDisappear() }
        harness.sut.setWorkflowRunMessageLock(true)
        #expect(harness.sut.columns.first?.messageLock == .runCancelled)

        // when
        harness.sut.setWorkflowRunMessageLock(false)

        // then
        #expect(harness.sut.columns.first?.messageLock == nil)
        #expect(harness.sut.columns.first?.laneComposerLock == nil)
    }

    @Test func givenALockedLane_whenTheViewDisappears_thenTheLockIsCleared() async throws {
        // given
        let harness = makeSUT()
        _ = try await appearWithLane(harness)
        harness.sut.setWorkflowRunMessageLock(true)

        // when
        harness.sut.didDisappear()

        // then
        #expect(!harness.sut.isRunMessageLocked)
    }

    @Test func givenATakenOverLaneOfACancelledRun_whenItIsLocked_thenTheTakeoverCopyWins() async throws {
        // given
        let harness = makeSUT()
        _ = try await appearWithLane(harness, raw: ["taken_over": .bool(true)])
        defer { harness.sut.didDisappear() }

        // when
        harness.sut.setWorkflowRunMessageLock(true)

        // then
        #expect(harness.sut.columns.first?.laneComposerLock == .takenOver)
        #expect(MessageBoxDisabledReason.runCancelled.text == "Messages are off — this run was cancelled")
        #expect(MessageBoxDisabledReason.runCancelled.showsLock)
    }

    @Test func givenALockedLane_whenSubmittingAndCancelling_thenSubmitIsRefusedAndCancelStaysAllowed() async throws {
        // given
        let harness = makeSUT()
        _ = try await appearWithLane(harness)
        defer { harness.sut.didDisappear() }
        given(harness.useCase).sendMessage(.any, text: .any, now: .any).willReturn([:])
        given(harness.useCase).cancelMessage(.any, messageID: .any).willReturn()
        harness.sut.setWorkflowRunMessageLock(true)
        let column = try #require(harness.sut.columns.first)

        // when
        let accepted = column.onSubmitMessage?("too late", false)
        column.onCancelMessage?("message-1")

        // then
        #expect(accepted == false)
        verify(harness.useCase).sendMessage(.any, text: .any, now: .any).called(0)
        await verify(harness.useCase)
.cancelMessage(.value("lane"), messageID: .value("message-1"))
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenAnInspectorColumn_whenMessagingIsUnsupported_thenOnlyTheInspectorComposerLocksAndSendsAreRefused() async throws {
        // given
        let harness = makeSUT()
        let inspector = harness.sut.makeWorkflowActivity()
        let node = task(id: "node")
        harness.tasksBox.value = ["node": node]
        given(harness.useCase).sendMessage(.any, text: .any, now: .any).willReturn([:])
        inspector.didAppear()
        defer { inspector.didDisappear() }
        harness.tasksSubject.send([node])
        await waitUntil { inspector.columns.count == 1 && inspector.isPresentationSettled }

        // when
        inspector.setMessagingUnsupported(true)

        // then
        let column = try #require(inspector.columns.first)
        #expect(column.chrome == .inspector)
        #expect(column.messageLock == .messagingUnsupported)
        #expect(column.inspectorMessagingUnsupported)
        #expect(column.onSubmitMessage?("blocked", false) == false)
        #expect(column.onSubmitMessage?("blocked", true) == false)
        verify(harness.useCase).sendMessage(.any, text: .any, now: .any).called(0)

        // when
        inspector.setMessagingUnsupported(false)

        // then
        #expect(inspector.columns.first?.messageLock == nil)
        #expect(inspector.columns.first?.inspectorMessagingUnsupported == false)
    }

    @Test func givenALaneColumn_whenMessagingIsUnsupported_thenTheLaneIsUnchanged() async throws {
        // given
        let harness = makeSUT()
        _ = try await appearWithLane(harness)
        defer { harness.sut.didDisappear() }
        let before = harness.sut.presentationWriteCount

        // when
        harness.sut.setMessagingUnsupported(true)

        // then
        #expect(harness.sut.columns.first?.chrome == .lane)
        #expect(harness.sut.columns.first?.messageLock == nil)
        #expect(harness.sut.columns.first?.laneComposerLock == nil)
        #expect(harness.sut.presentationWriteCount == before)
    }

    @Test func givenAnInspectorColumn_whenTheRunLockIsSet_thenItsComposerIsUnaffected() async throws {
        // given
        let harness = makeSUT()
        let inspector = harness.sut.makeWorkflowActivity()
        let node = task(id: "node")
        harness.tasksBox.value = ["node": node]
        inspector.didAppear()
        defer { inspector.didDisappear() }
        harness.tasksSubject.send([node])
        await waitUntil { inspector.columns.count == 1 && inspector.isPresentationSettled }

        // when
        inspector.setWorkflowRunMessageLock(true)

        // then
        #expect(inspector.columns.first?.messageLock == nil)
    }
}
