import Foundation
import MonitorCore

// MARK: - Parallel activity handoff

extension ParallelVM {
    func preparePreviousActivity(_ dirty: inout [String: ParallelColumnInput]) {
        for id in dirty.keys {
            dirty[id]?.previousMarkdown = presentations[id]?.markdown ?? [:]
            dirty[id]?.previousActivitySnapshot = presentations[id]?.activitySnapshot
        }
    }

    /// Seeds the already displayed detail before membership subscriptions can refresh its lane.
    func seedConversationActivity(_ snapshot: ConversationActivitySnapshot, state: ParallelColumnUIState) {
        guard !didSubscribe else { return }
        let conversation = snapshot.conversation
        let id = conversation.id
        state.activityMembers = snapshot.loadedMembers
        state.oldestSequences = snapshot.oldestSequences
        state.inventoryMembers = Dictionary(conversation.members.map { ($0.taskID, $0) }, uniquingKeysWith: { _, fresh in fresh })
        state.inventorySession = snapshot.session
        state.inventoryCursor = snapshot.cursor
        state.inventoryComplete = snapshot.inventoryComplete
        state.inventoryIncomplete = snapshot.inventoryIncomplete
        state.inventoryError = snapshot.inventoryError
        state.paginationRevision = snapshot.paginationRevision
        uiStates[id] = state
        conversations = [conversation]
        orderedConversations = [conversation]
        conversationByID[id] = conversation
        for member in conversation.members { ownerByMember[member.taskID] = id }
        memberIDs = conversation.members.map(\.taskID)
        var value = ParallelColumnPresentation(id: id, task: conversation.current, title: snapshot.title,
            subtitle: ParallelColumnModel.subtitle(repoPath: conversation.current.repoPath, backend: conversation.current.backend,
                                                   turns: conversation.members.count),
            isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
            start: conversation.first.startedAt, memberTaskIDs: Set(memberIDs))
        if let presentation = snapshot.presentation {
            value.rows = presentation.rows
            value.activitySnapshot = presentation.activitySnapshot
            value.activityRows = presentation.activityRows
            value.markdown = presentation.markdown
            value.liveStep = presentation.liveStep
            value.pendingMessages = presentation.pendingMessages
            value.isLoading = presentation.isLoading
            value.emptyText = presentation.emptyText
            value.history = presentation.history
            value.paginationRevision = snapshot.paginationRevision
            value.stepCountText = presentation.stepCountText
            value.noToolCallsText = presentation.noToolCallsText
        }
        presentations[id] = value
        descriptors[id] = value
        if let input = snapshot.input {
            completedInputs[id] = ParallelColumnInput(base: value, members: input.members,
                events: input.events, snapshot: input.snapshot, previousMarkdown: value.markdown)
        }
        refreshingRetainedIDs.insert(id)
        publishColumns()
    }

}
