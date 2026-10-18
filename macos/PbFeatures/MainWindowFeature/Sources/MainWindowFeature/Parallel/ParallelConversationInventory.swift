import Foundation
import MonitorCore
import PbRepository

/// Keeps bounded task headers and opaque cursors; activity remains owned by repository leases.
@MainActor
final class ParallelConversationInventory {
    private struct Binding {
        let conversation: Conversation
        let state: ParallelColumnUIState
        let session: String
    }

    private let fetch: (String, String?) async throws -> TaskHistoryPage?
    private let onInventory: () -> Void
    private let onChange: (String) -> Void
    private var bindings: [String: Binding] = [:]
    private var visible: Set<String> = []
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var tokens: [ObjectIdentifier: UUID] = [:]
    private var errors: [ObjectIdentifier: String] = [:]

    init(useCase: any ParallelUseCase, onInventory: @escaping () -> Void, onChange: @escaping (String) -> Void,
         fetch: ((String, String?) async throws -> TaskHistoryPage?)? = nil) {
        self.fetch = fetch ?? { session, cursor in try await useCase.conversationHistory(sessionID: session, cursor: cursor) }
        self.onInventory = onInventory
        self.onChange = onChange
    }

    func update(conversations: [Conversation], visible: Set<String>, states: [String: ParallelColumnUIState]) {
        let previous = Set(bindings.filter { !$0.value.state.inventoryComplete }.keys)
        bindings = Dictionary(conversations.compactMap { conversation in
            guard let state = states[conversation.id], let session = conversation.current.sessionID, !session.isEmpty else { return nil }
            if state.inventorySession != session {
                let key = ObjectIdentifier(state)
                tasks[key]?.cancel()
                tasks[key] = nil
                tokens[key] = nil
                errors[key] = nil
                state.inventorySession = session
                state.inventoryCursor = nil
                state.inventoryComplete = false
                state.inventoryMembers.removeAll()
                state.activityMembers = [conversation.current.taskID]
                state.oldestSequences.removeAll()
            }
            return (conversation.id, Binding(conversation: conversation, state: state, session: session))
        }, uniquingKeysWith: { first, _ in first })
        self.visible = visible
        let active = Set(bindings.filter { visible.contains($0.key) }.map { ObjectIdentifier($0.value.state) })
        for key in tasks.keys where !active.contains(key) { tasks[key]?.cancel(); tasks[key] = nil; tokens[key] = nil }
        let known = Set(bindings.values.map { ObjectIdentifier($0.state) })
        errors = errors.filter { known.contains($0.key) }
        let current = Set(bindings.filter { !$0.value.state.inventoryComplete }.keys)
        for id in current.subtracting(previous) {
            if let memberID = bindings[id]?.conversation.current.taskID { onChange(memberID) }
        }
    }

    func hasMore(_ id: String) -> Bool { bindings[id].map { !$0.state.inventoryComplete } ?? false }
    func isLoading(_ id: String) -> Bool { bindings[id].map { tasks[ObjectIdentifier($0.state)] != nil } ?? false }
    func error(_ id: String) -> String? { bindings[id].flatMap { errors[ObjectIdentifier($0.state)] } }

    @discardableResult func loadOlder(_ id: String) -> Bool {
        guard visible.contains(id), let binding = bindings[id], !binding.state.inventoryComplete else { return false }
        let key = ObjectIdentifier(binding.state)
        guard tasks[key] == nil else { return false }
        let token = UUID()
        tokens[key] = token
        errors[key] = nil
        let cursor = binding.state.inventoryCursor
        tasks[key] = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await fetch(binding.session, cursor)
                guard isCurrent(key, token: token, session: binding.session), !Task.isCancelled else { return }
                if let page {
                    apply(page, binding: binding, key: key, previousCursor: cursor)
                } else {
                    binding.state.inventoryComplete = true
                }
            } catch {
                guard isCurrent(key, token: token, session: binding.session), !Task.isCancelled else { return }
                errors[key] = "Conversation history could not be loaded. Retry to continue."
            }
            tasks[key] = nil
            tokens[key] = nil
            binding.state.paginationRevision &+= 1
            onInventory()
            onChange(binding.conversation.current.taskID)
        }
        onChange(binding.conversation.current.taskID)
        return true
    }

    private func isCurrent(_ key: ObjectIdentifier, token: UUID, session: String) -> Bool {
        tokens[key] == token && bindings.contains { id, binding in
            visible.contains(id) && ObjectIdentifier(binding.state) == key && binding.session == session
        }
    }

    private func apply(_ page: TaskHistoryPage, binding: Binding, key: ObjectIdentifier, previousCursor: String?) {
        let more = page.page.hasMore || page.page.bootstrapPending
        if more, page.page.nextCursor == previousCursor, !page.page.bootstrapPending {
            errors[key] = "Conversation history did not advance. Retry to continue."
            return
        }
        binding.state.inventoryCursor = page.page.nextCursor
        binding.state.inventoryComplete = !more
        let byID = Dictionary((Array(binding.state.inventoryMembers.values) + page.items + page.relatedItems
            + binding.conversation.members).map { ($0.taskID, $0) }, uniquingKeysWith: { _, fresh in fresh })
        let candidates = Array(byID.values)
        let members = WorkflowOrchestratorConversation.members(containing: binding.conversation.current.taskID, in: candidates)
            ?? Lineage.conversation(containing: binding.conversation.current.taskID, in: candidates)?.members ?? binding.conversation.members
        binding.state.inventoryMembers = Dictionary(members.map { ($0.taskID, $0) }, uniquingKeysWith: { _, fresh in fresh })
        if page.page.bootstrapPending { errors[key] = "Conversation history is still indexing. Retry to continue." }
    }

    func teardown() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
        tokens.removeAll()
        bindings.removeAll()
        errors.removeAll()
        visible.removeAll()
    }
}
