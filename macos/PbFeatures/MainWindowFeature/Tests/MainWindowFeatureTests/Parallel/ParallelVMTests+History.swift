import Combine
import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenUnvisitedColumns_whenOlderActivityIsRequested_thenOnlyVisibleColumnsRequestAndDuplicatesCoalesce() async throws {
        // given
        let harness = historyHarness()
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let visible = try #require(harness.sut.columns.first)
        #expect(visible.isVisible && visible.history.hasMore)
        #expect(!harness.sut.columns[1].isResident && !harness.sut.columns[1].isVisible)
        #expect(harness.sut.columns[1].onLoadMore == nil)
        // when
        visible.onLoadMore?()
        visible.onLoadMore?()
        await waitUntil { harness.sut.columns.first?.history.isLoading == true }
        // then
        #expect(harness.loadCallsBox.value == [visible.task.taskID])
        harness.sut.didDisappear()
    }

    @Test func givenResumedConversation_whenOlderPagesFinish_thenRenderedRowsRemainAContiguousChronologicalSuffix() async throws {
        let harness = makeSUT()
        let first = task(id: "first", status: "completed", startedAt: Date(timeIntervalSince1970: 0))
        let second = task(id: "second", status: "running", startedAt: Date(timeIntervalSince1970: 1), parentTaskID: "first")
        seedHistory(harness, ids: ["first", "second"], sequence: 100)
        harness.tasksBox.value = ["first": first, "second": second]
        harness.sut.didAppear()
        harness.tasksSubject.send([first, second])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        #expect(Set(harness.sut.columns[0].rows.map(\.taskID)) == ["second"])
        #expect(harness.leasesBox.value.keys.count == 2)
        harness.sut.columns.first?.onLoadMore?()
        sendHistory(harness, id: "second", history: EventHistoryState(hasMore: true, isLoading: true))
        finishPage(harness, id: "second", sequence: 50, hasMore: false)
        await waitUntil { harness.sut.columns.first?.paginationRevision == 1 && harness.sut.isPresentationSettled }
        #expect(Set(harness.sut.columns[0].rows.map(\.taskID)) == ["second"])
        harness.sut.columns.first?.onLoadMore?()
        await waitUntil { harness.sut.columns.first?.paginationRevision == 2 && harness.sut.isPresentationSettled }
        let rows = harness.sut.columns[0].rows
        #expect(rows.first?.taskID == "first")
        #expect(rows.last?.taskID == "second")
        #expect(harness.loadCallsBox.value == ["second"], "revealing a previous seeded tail does not request disk history yet")
        harness.sut.columns.first?.onLoadMore?()
        #expect(harness.loadCallsBox.value == ["second", "first"])
        harness.sut.didDisappear()
    }

    @Test func givenCursorAdvancingPageWithoutNewDecodedRows_whenItCompletes_thenLoadingStopsAndMoreHistoryRemainsAvailable() async throws {
        // given
        let harness = historyHarness()
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let id = try #require(harness.sut.columns.first?.task.taskID)
        // when
        harness.sut.columns.first?.onLoadMore?()
        sendHistory(harness, id: id, history: EventHistoryState(hasMore: true, isLoading: true))
        finishPage(harness, id: id, sequence: 100, hasMore: true)
        await waitUntil { harness.sut.columns.first?.paginationRevision == 1 && harness.sut.isPresentationSettled }
        // then
        #expect(harness.sut.columns.first?.history.isLoading == false)
        #expect(harness.sut.columns.first?.history.error == nil)
        #expect(harness.loadCallsBox.value.count == 1)
        harness.sut.columns.first?.onLoadMore?()
        #expect(harness.loadCallsBox.value.count == 2)
        harness.sut.didDisappear()
    }

    @Test func givenPagedColumn_whenItIsEvictedAndRevisited_thenOnlyItsRetainedSequenceBoundaryIsRestored() async throws {
        // given
        let harness = historyHarness()
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let id = try #require(harness.sut.columns.first?.task.taskID)
        harness.sut.columns.first?.onLoadMore?()
        sendHistory(harness, id: id, history: EventHistoryState(hasMore: true, isLoading: true))
        finishPage(harness, id: id, sequence: 50, hasMore: true)
        await waitUntil { harness.sut.columns.first?.history.isLoading == false && harness.sut.isPresentationSettled }
        // when
        harness.sut.updateViewport(offset: 1684, width: 421)
        await waitUntil { harness.releasedBox.value.contains(id) && harness.sut.isPresentationSettled }
        #expect(harness.sut.columnState(for: id).oldestSequences[id] == 50)
        harness.acquireEffectBox.value = { memberID in
            guard memberID == id else { return }
            self.seedHistory(harness, ids: [id], sequence: 100)
        }
        harness.sut.updateViewport(offset: 0, width: 421)
        await waitUntil { harness.loadCallsBox.value.count == 2 }
        sendHistory(harness, id: id, history: EventHistoryState(hasMore: true, isLoading: true))
        finishPage(harness, id: id, sequence: 50, hasMore: true)
        await waitUntil { harness.sut.columns.first?.history.isLoading == false && harness.sut.isPresentationSettled }
        // then
        #expect(harness.loadCallsBox.value == [id, id])
        #expect(harness.sut.columns.first?.rows.first?.id.contains("50") == true)
        harness.sut.didDisappear()
    }

    @Test func givenCapturedVisibleAction_whenViewportChanges_thenItsStaleCallbackCannotLoadBufferedOrEvictedHistory() async throws {
        // given
        let harness = historyHarness()
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let action = harness.sut.columns.first?.onLoadMore
        // when
        harness.sut.updateViewport(offset: 421, width: 421)
        await waitUntil { harness.sut.columns.first?.isVisible == false && harness.sut.isPresentationSettled }
        action?()
        // then
        #expect(harness.loadCallsBox.value.isEmpty)
        harness.sut.didDisappear()
    }

    @Test func givenLargeMembership_whenLeaseAcquisitionStarts_thenVisibleCurrentTurnsAreAcquiredBeforeNeighborHistory() {
        // given
        let columns = (0 ..< 3).map { column in
            Conversation(members: (0 ..< 4).map { turn in task(id: "c\(column)-t\(turn)") })
        }
        // when
        let order = ParallelLeaseOrder.members(columns)
        // then
        #expect(Array(order.prefix(3)) == ["c0-t3", "c1-t3", "c2-t3"])
        #expect(order.count == 12)
    }

    @Test func givenOlderPage_whenFileGenerationChanges_thenRestorationBoundaryIsDiscarded() async throws {
        let harness = historyHarness()
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let id = try #require(harness.sut.columns.first?.id)
        harness.sut.columnState(for: id).oldestSequences[id] = 10
        harness.sut.columns.first?.onLoadMore?()
        sendHistory(harness, id: id, history: EventHistoryState(hasMore: true, isLoading: true))
        sendHistory(harness, id: id, history: EventHistoryState(hasMore: false, generation: 1))
        await waitUntil { harness.sut.columns.first?.paginationRevision == 1 && harness.sut.isPresentationSettled }
        #expect(harness.sut.columnState(for: id).oldestSequences[id] == nil)
        #expect(harness.sut.columns.first?.history.isLoading == false)
        harness.sut.didDisappear()
    }

    @Test func givenQueuedHistoryPublisher_whenColumnIsReleased_thenItsLateValueCannotPublish() async throws {
        let harness = historyHarness()
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let id = try #require(harness.sut.columns.first?.id)
        let oldPublisher = try #require(harness.historySubjectsBox.value[id])
        harness.sut.updateViewport(offset: 1684, width: 421)
        oldPublisher.send(EventHistoryState(hasMore: true, isLoading: true, error: "obsolete"))
        await waitUntil { harness.sut.isPresentationSettled }
        #expect(harness.sut.columns.first?.history.error == nil)
        #expect(harness.sut.columns.first?.isVisible == false)
        #expect(harness.sut.columns.first?.isResident == true)
        harness.sut.didDisappear()
    }

    @Test func givenLargeLeaseBurst_whenCancelledAtYield_thenRemainingMembersAreNotAcquired() async {
        var acquired: [String] = []
        var bursts: [Int] = []
        var coordinator: ParallelLeaseAcquisition?
        coordinator = ParallelLeaseAcquisition(acquire: { acquired.append($0); return true }, onBurst: { ids, _ in
            bursts.append(ids.count)
            coordinator?.cancel()
        }, onFinish: {})
        coordinator?.update(order: (0 ..< 50).map(String.init), existing: [])
        await waitUntil { !bursts.isEmpty }
        #expect(acquired.count <= 4)
        #expect(coordinator?.isSettled == true)
        coordinator = nil
    }

    @Test func givenPausedReadingInRevealedHistory_whenNewResumeTurnHasOlderPages_thenRowsAndAnchorRemainAndNewestGapPagesFirst() async throws {
        let harness = makeSUT()
        let first = task(id: "first", status: "completed", startedAt: Date(timeIntervalSince1970: 0))
        let second = task(id: "second", status: "completed", startedAt: Date(timeIntervalSince1970: 1), parentTaskID: "first")
        let third = task(id: "third", startedAt: Date(timeIntervalSince1970: 2), parentTaskID: "second")
        seedHistory(harness, ids: ["first", "second", "third"], sequence: 100)
        harness.historyBox.value["second"] = EventHistoryState()
        harness.tasksBox.value = ["first": first, "second": second, "third": third]
        harness.sut.didAppear()
        harness.tasksSubject.send([first, second])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        harness.sut.columns.first?.onLoadMore?()
        await waitUntil { harness.sut.columns.first?.paginationRevision == 1 && harness.sut.isPresentationSettled }
        let state = harness.sut.columnState(for: "first")
        let row = try #require(harness.sut.columns.first?.rows.first)
        let anchor = ParallelVerticalAnchor(id: row.id, index: 0, relativeOffset: -12)
        state.anchor = anchor
        state.followLive.suspend()
        harness.tasksSubject.send([first, second, third])
        await waitUntil { harness.sut.columns.first?.task.taskID == "third" && harness.sut.isPresentationSettled }
        #expect(harness.sut.columns[0].rows.contains { $0.id == row.id })
        #expect(state.anchor == anchor)
        #expect(!state.followLive.isFollowing)
        #expect(state.activityMembers == ["first", "second", "third"])
        harness.sut.columns.first?.onLoadMore?()
        #expect(harness.loadCallsBox.value == ["third"], "a newly introduced incomplete turn is filled before expanding older history")
        harness.sut.didDisappear()
    }

    @Test func givenHiddenPreviousTurnStillLoading_whenCurrentTailIsReady_thenVisiblePaginationIsAccepted() async {
        let harness = makeSUT()
        let previous = task(id: "previous", status: "completed", startedAt: Date(timeIntervalSince1970: 0))
        let current = task(id: "current", parentTaskID: "previous")
        seedHistory(harness, ids: ["previous", "current"], sequence: 100)
        harness.historyBox.value["previous"] = EventHistoryState(isLoading: true)
        harness.tasksBox.value = ["previous": previous, "current": current]
        harness.sut.didAppear()
        harness.tasksSubject.send([previous, current])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        #expect(harness.sut.leasedMemberCount == 2)
        #expect(harness.sut.columns.first?.history.isLoading == false)
        #expect(harness.sut.columns.first?.onLoadMore?() == true)
        #expect(harness.loadCallsBox.value == ["current"])
        harness.sut.didDisappear()
    }

    @Test func givenSourceRejectsStalePaginationOffer_whenVisibleRequestsOlder_thenNoPendingLoadingOperationIsRetained() async {
        let harness = historyHarness()
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        harness.loadAdmissionBox.value = false
        #expect(harness.sut.columns.first?.onLoadMore?() == false)
        await waitUntil { harness.sut.isPresentationSettled }
        #expect(harness.sut.columns.first?.history.isLoading == false)
        #expect(harness.loadCallsBox.value.isEmpty)
        harness.loadAdmissionBox.value = true
        #expect(harness.sut.columns.first?.onLoadMore?() == true)
        #expect(harness.loadCallsBox.value.count == 1)
        harness.sut.didDisappear()
    }

    @Test func givenRetainedRestoreTarget_whenSourceRejectsAdmission_thenRestorationStopsWithRetryInsteadOfRecursing() async throws {
        let harness = historyHarness()
        await waitUntil { harness.sut.columns.count == 8 && harness.sut.isPresentationSettled }
        let id = try #require(harness.sut.columns.first?.id)
        harness.sut.columnState(for: id).oldestSequences[id] = 50
        harness.sut.updateViewport(offset: 1684, width: 421)
        await waitUntil { harness.releasedBox.value.contains(id) && harness.sut.isPresentationSettled }
        harness.loadAdmissionBox.value = false
        harness.sut.updateViewport(offset: 0, width: 421)
        await waitUntil { harness.sut.columns.first?.history.error != nil && harness.sut.isPresentationSettled }
        #expect(harness.sut.columns.first?.history.isLoading == false)
        #expect(harness.sut.columns.first?.history.error?.contains("Retry") == true)
        #expect(harness.loadCallsBox.value.isEmpty)
        #expect(harness.sut.columnState(for: id).oldestSequences[id] == 50)
        harness.sut.didDisappear()
    }

    private func historyHarness() -> SUT {
        let harness = makeSUT()
        harness.sut.updateViewport(offset: 0, width: 421)
        let tasks = (0 ..< 8).map { task(id: "history-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        seedHistory(harness, ids: tasks.map(\.taskID), sequence: 100)
        harness.tasksBox.value = Dictionary(uniqueKeysWithValues: tasks.map { ($0.taskID, $0) })
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        return harness
    }

    private func seedHistory(_ harness: SUT, ids: [String], sequence: Int) {
        for id in ids {
            let event = TaskEvent(line: "{\"v\":1,\"seq\":\(sequence),\"kind\":\"assistant_text\",\"text\":\"synthetic history\"}")!
            harness.eventsBox.value[id] = [event]
            harness.itemsBox.value[id] = Timeline.items(from: [event])
            harness.availabilityBox.value[id] = .available
            harness.historyBox.value[id] = EventHistoryState(hasMore: true)
            harness.itemSubjectsBox.value[id] = PassthroughSubject()
        }
    }

    private func sendHistory(_ harness: SUT, id: String, history: EventHistoryState) {
        harness.historyBox.value[id] = history
        harness.historySubjectsBox.value[id]?.send(history)
    }

    private func finishPage(_ harness: SUT, id: String, sequence: Int, hasMore: Bool) {
        let event = TaskEvent(line: "{\"v\":1,\"seq\":\(sequence),\"kind\":\"assistant_text\",\"text\":\"synthetic older history\"}")!
        harness.eventsBox.value[id] = [event]
        let items = Timeline.items(from: [event])
        harness.itemsBox.value[id] = items
        harness.itemSubjectsBox.value[id]?.send(items)
        sendHistory(harness, id: id, history: EventHistoryState(hasMore: hasMore))
    }
}
