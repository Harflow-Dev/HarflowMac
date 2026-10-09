import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenInventoryPageWithOlderTurnAndUnrelatedGroup_whenLoaded_thenOnlyTheConversationIsExtended() async throws {
        let current = task(id: "current", parentTaskID: "older")
        let older = task(id: "older", startedAt: Date(timeIntervalSince1970: 0))
        let unrelated = task(id: "foreign", group: "other")
        let state = ParallelColumnUIState()
        let useCase = MockParallelUseCase()
        let page = try inventoryPage([older, unrelated], cursor: nil)
        given(useCase).conversationHistory(sessionID: .any, cursor: .any).willReturn(page)
        var completed = false
        let inventory = ParallelConversationInventory(useCase: useCase, onInventory: { completed = true }, onChange: { _ in })
        let conversation = Conversation(members: [current])
        inventory.update(conversations: [conversation], visible: [conversation.id], states: [conversation.id: state])
        inventory.loadOlder(conversation.id)
        inventory.loadOlder(conversation.id)
        await waitUntil { completed }
        #expect(Set(state.inventoryMembers.keys) == ["older", "current"])
        #expect(state.inventoryComplete)
        let extended = ParallelMembership.extending(conversation, states: [conversation.id: state])
        #expect(extended.id == "older")
        #expect(extended.current.taskID == "current")
        #expect(state.paginationRevision == 1)
        inventory.teardown()
    }

    @Test func givenInventoryContinuation_whenCursorDoesNotAdvance_thenRetryRetainsItsCursor() async throws {
        let current = task(id: "current")
        let state = ParallelColumnUIState()
        state.inventorySession = current.sessionID
        state.inventoryCursor = "opaque"
        let useCase = MockParallelUseCase()
        let page = try inventoryPage([], cursor: "opaque", more: true)
        given(useCase).conversationHistory(sessionID: .any, cursor: .any).willReturn(page)
        let inventory = ParallelConversationInventory(useCase: useCase, onInventory: {}, onChange: { _ in })
        let conversation = Conversation(members: [current])
        inventory.update(conversations: [conversation], visible: [conversation.id], states: [conversation.id: state])
        inventory.loadOlder(conversation.id)
        await waitUntil { state.paginationRevision == 1 }
        #expect(inventory.error(conversation.id)?.contains("did not advance") == true)
        #expect(state.inventoryCursor == "opaque")
        #expect(inventory.hasMore(conversation.id))
        inventory.teardown()
    }

    @Test func givenDelayedInventoryPage_whenViewportLeaves_thenItsResultCannotExtendMembership() async throws {
        let current = task(id: "current", parentTaskID: "older")
        let older = task(id: "older")
        let state = ParallelColumnUIState()
        let useCase = MockParallelUseCase()
        let page = try inventoryPage([older], cursor: nil)
        let gate = ParallelInventoryGate()
        let inventory = ParallelConversationInventory(useCase: useCase, onInventory: {}, onChange: { _ in }, fetch: { _, _ in
            await gate.wait()
            return page
        })
        let conversation = Conversation(members: [current])
        inventory.update(conversations: [conversation], visible: [conversation.id], states: [conversation.id: state])
        inventory.loadOlder(conversation.id)
        await waitUntil { gate.started }
        inventory.update(conversations: [conversation], visible: [], states: [conversation.id: state])
        gate.release()
        await waitUntil { gate.finished }
        #expect(state.inventoryMembers.isEmpty)
        #expect(state.paginationRevision == 0)
        inventory.teardown()
    }

    @Test func givenKnownEventHistoriesExhausted_whenInventoryDiscoversPreviousTurn_thenIdentityStateAndCancelScopeArePreserved() async throws {
        let harness = makeSUT()
        let current = task(id: "current", parentTaskID: "older")
        let older = task(id: "older", startedAt: Date(timeIntervalSince1970: 0))
        harness.conversationPagesBox.value = [try inventoryPage([older], cursor: nil)]
        harness.tasksBox.value = ["current": current, "older": older]
        harness.availabilityBox.value = ["current": .available, "older": .available]
        harness.sut.didAppear()
        harness.tasksSubject.send([current])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }
        let state = harness.sut.columnState(for: "current")
        state.expandedGroups = ["keep"]
        #expect(harness.sut.columns.first?.history.hasMore == true)
        harness.sut.columns.first?.onLoadMore?()
        await waitUntil { harness.sut.columns.first?.id == "older" && harness.sut.isPresentationSettled }
        #expect(harness.sut.columnState(for: "older") === state)
        #expect(harness.sut.columns.first?.memberTaskIDs == ["older", "current"])
        #expect(harness.sut.columns.first?.history.hasMore == true, "the discovered previous seeded tail remains hidden until chronological reveal")
        harness.sut.columns.first?.onLoadMore?()
        await waitUntil { harness.sut.columns.first?.paginationRevision == 2 && harness.sut.isPresentationSettled }
        #expect(harness.sut.columns.first?.history.hasMore == false)
        var captured: ViewEvent?
        let subscription = harness.sut.objectDidPublishViewEvent.publisher.sink { captured = $0 }
        harness.sut.didTapCancelAll()
        await waitUntil { captured?.dialog != nil }
        let dialog = try #require(captured?.dialog)
        dialog.actions.first?.action()
        verify(harness.useCase).runningInSubtrees(of: .value(["older", "current"])).called(1)
        subscription.cancel()
        harness.sut.didDisappear()
    }

    @Test func givenDelayedInventory_whenHarnessSessionChanges_thenOldOperationCannotKeepNewSessionLoading() async throws {
        let current = task(id: "current", sessionID: "old-session")
        let changed = task(id: "current", sessionID: "new-session")
        let state = ParallelColumnUIState()
        let useCase = MockParallelUseCase()
        let page = try inventoryPage([], cursor: "obsolete", more: true)
        let gate = ParallelInventoryGate()
        let inventory = ParallelConversationInventory(useCase: useCase, onInventory: {}, onChange: { _ in }, fetch: { _, _ in
            await gate.wait()
            return page
        })
        let original = Conversation(members: [current])
        inventory.update(conversations: [original], visible: [original.id], states: [original.id: state])
        inventory.loadOlder(original.id)
        await waitUntil { gate.started }
        state.activityMembers = ["earlier", "current"]
        state.oldestSequences = ["current": 10]
        let replacement = Conversation(members: [changed])
        inventory.update(conversations: [replacement], visible: [replacement.id], states: [replacement.id: state])
        #expect(!inventory.isLoading(replacement.id))
        #expect(state.inventorySession == "new-session")
        #expect(state.activityMembers == ["current"])
        #expect(state.oldestSequences.isEmpty)
        #expect(state.inventoryCursor == nil)
        gate.release()
        await waitUntil { gate.finished }
        #expect(state.inventoryCursor == nil)
        #expect(state.paginationRevision == 0)
        inventory.teardown()
    }

    private func inventoryPage(_ tasks: [TaskInfo], cursor: String?, more: Bool = false) throws -> TaskHistoryPage {
        try #require(TaskHistoryPage(raw: ["items": .array(tasks.map { .object($0.raw) }),
            "next_cursor": cursor.map(JSONValue.string) ?? .null, "has_more": .bool(more), "bootstrap_pending": .bool(false)]))
    }
}

@MainActor
private final class ParallelInventoryGate {
    var started = false
    var finished = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
        finished = true
    }

    func release() { continuation?.resume(); continuation = nil }
}
