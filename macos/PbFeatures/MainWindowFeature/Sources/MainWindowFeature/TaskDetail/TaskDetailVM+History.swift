import Foundation
import MonitorCore

extension TaskDetailVM {
    func loadConversationHistory(initial: Bool) {
        guard !conversationLoading else { return }
        conversationLoading = true
        conversationError = nil
        conversationLookup = Task { [weak self] in
            guard let self else { return }
            let resolved = await useCase.resolveTask(currentTaskID)
            guard !Task.isCancelled else { return }
            if initial { recomputeMembersAndLeases() }
            guard let session = (resolved ?? task)?.sessionID else {
                conversationLoading = false
                recompute()
                return
            }
            do {
                if let page = try await useCase.conversationHistory(sessionID: session, cursor: initial ? nil : conversationCursor) {
                    guard !Task.isCancelled else { return }
                    applyConversationPage(page, initial: initial)
                }
            } catch {
                guard !Task.isCancelled else { return }
                conversationError = "Conversation history could not be loaded. Retry to continue."
            }
            conversationLoading = false
            recompute()
        }
    }

    func applyConversationPage(_ page: TaskHistoryPage, initial: Bool) {
                    conversationCursor = page.page.nextCursor
                    conversationHasMore = page.page.hasMore || page.page.bootstrapPending
                    conversationHistoryIncomplete = page.page.historyIncomplete
                    if page.page.bootstrapPending {
                        conversationError = "Conversation history is still indexing. Load more to continue."
                    }
                    recomputeMembersAndLeases()
                    if !initial, let older = conversationMembers.last(where: { !loadedActivityMembers.contains($0.taskID) }) {
                        loadedActivityMembers.insert(older.taskID)
                        acquireMemberLease(older.taskID)
                    }
    }

}
