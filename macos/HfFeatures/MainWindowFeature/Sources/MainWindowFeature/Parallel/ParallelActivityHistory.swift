import Combine
import Foundation
import HfRepository
import MonitorCore

// MARK: - ParallelActivityHistory

/// Coordinates bounded older pages without retaining activity arrays outside repository leases.
@MainActor
final class ParallelActivityHistory {
    private struct Request {
        let memberID: String
        let generation: Int
        var observedLoading = false
    }

    private let useCase: any ParallelUseCase
    private let inventory: ParallelConversationInventory
    private let onChange: (String) -> Void
    private var subscriptions: [String: AnyCancellable] = [:]
    private var leaseIDs: [String: UUID] = [:]
    private var histories: [String: EventHistoryState] = [:]
    private var owners: [String: String] = [:]
    private var members: [String: [String]] = [:]
    private var states: [String: ParallelColumnUIState] = [:]
    private var visible: Set<String> = []
    private var requests: [String: Request] = [:]
    private var restoreTargets: [String: [String: String]] = [:]
    private var restoreGenerations: [String: Int] = [:]
    private var errors: [String: String] = [:]

    init(useCase: any ParallelUseCase, onInventory: @escaping () -> Void, onChange: @escaping (String) -> Void) {
        self.inventory = ParallelConversationInventory(useCase: useCase, onInventory: onInventory, onChange: onChange)
        self.useCase = useCase
        self.onChange = onChange
    }

    func update(conversations: [Conversation], visible: Set<String>, states: [String: ParallelColumnUIState]) {
        let current = Dictionary(conversations.map { ($0.id, $0.members.map(\.taskID)) }, uniquingKeysWith: { first, _ in first })
        let ownerByMember = Dictionary(conversations.flatMap { conversation in conversation.members.map { ($0.taskID, conversation.id) } },
                                       uniquingKeysWith: { first, _ in first })
        let stateIDs = Dictionary(states.map { (ObjectIdentifier($0.value), $0.key) }, uniquingKeysWith: { first, _ in first })
        var migratedErrors: [String: String] = [:]
        for (id, state) in self.states {
            if let currentID = stateIDs[ObjectIdentifier(state)], let error = errors[id] { migratedErrors[currentID] = error }
        }
        requests = Dictionary(requests.values.compactMap { request in ownerByMember[request.memberID].map { ($0, request) } },
                              uniquingKeysWith: { first, _ in first })
        var targets: [String: [String: String]] = [:]
        for values in restoreTargets.values {
            for (memberID, sequence) in values {
                if let id = ownerByMember[memberID] { targets[id, default: [:]][memberID] = sequence }
            }
        }
        restoreTargets = targets
        owners.removeAll(keepingCapacity: true)
        for memberID in leaseIDs.keys { if let id = ownerByMember[memberID] { owners[memberID] = id } }
        members = current
        self.visible = visible
        self.states = states
        errors = migratedErrors
        for (id, state) in states {
            let known = Set(members[id] ?? [])
            state.oldestSequences = state.oldestSequences.filter { known.contains($0.key) }
            synchronizeFrontier(id, state: state)
        }
        inventory.update(conversations: conversations, visible: visible, states: states)
        for id in restoreTargets.keys {
            restoreTargets[id] = restoreTargets[id]?.filter { states[id]?.oldestSequences[$0.key] == $0.value }
        }
        for id in visible { advanceRestoration(id) }
    }

    func acquire(_ memberID: String, conversationID: String, state: ParallelColumnUIState) {
        let token = UUID()
        leaseIDs[memberID] = token
        owners[memberID] = conversationID
        states[conversationID] = state
        synchronizeFrontier(conversationID, state: state)
        histories[memberID] = useCase.observation(for: memberID).presentationHistory
        if let row = state.oldestSequences[memberID] { restoreTargets[conversationID, default: [:]][memberID] = row }
    }

    func release(_ memberID: String) {
        guard let id = owners[memberID] else { return }
        rememberBoundary(memberID, conversationID: id)
        subscriptions[memberID] = nil
        leaseIDs[memberID] = nil
        histories[memberID] = nil
        restoreGenerations[memberID] = nil
        owners[memberID] = nil
        restoreTargets[id]?[memberID] = nil
        if requests[id]?.memberID == memberID { requests[id] = nil }
        if !owners.values.contains(id) { restoreTargets[id] = nil; errors[id] = nil; states[id] = nil }
    }

    func teardown() {
        inventory.teardown()
        subscriptions.removeAll()
        leaseIDs.removeAll()
        histories.removeAll()
        owners.removeAll()
        members.removeAll()
        states.removeAll()
        visible.removeAll()
        requests.removeAll()
        restoreTargets.removeAll()
        restoreGenerations.removeAll()
        errors.removeAll()
    }

    func changedObservation(_ memberID: String, frame: EventObservationFrame) {
        historyChanged(memberID, history: frame.presentationHistory)
    }

    func changedItems(_ memberID: String) {
        guard let id = owners[memberID] else { return }
        if requests[id] == nil { advanceRestoration(id) }
    }

    func state(for conversationID: String, allAcquired: Bool) -> EventHistoryState {
        let shown = revealedMembers(conversationID)
        let values = shown.compactMap { histories[$0] }
        let hidden = (members[conversationID] ?? []).contains { !shown.contains($0) }
        return EventHistoryState(hasMore: hidden || values.contains(where: \.hasMore) || inventory.hasMore(conversationID),
            isLoading: !allAcquired || inventory.isLoading(conversationID) || values.contains(where: \.isLoading) || requests[conversationID] != nil
                || !(restoreTargets[conversationID] ?? [:]).isEmpty,
            error: errors[conversationID] ?? values.compactMap(\.error).first ?? inventory.error(conversationID),
            generation: values.map(\.generation).max() ?? 0)
    }

    func isRevealed(_ memberID: String, conversationID: String) -> Bool {
        states[conversationID]?.activityMembers.contains(memberID) == true
    }

    private func revealedMembers(_ id: String) -> [String] {
        (members[id] ?? []).filter { isRevealed($0, conversationID: id) }
    }

    private func synchronizeFrontier(_ id: String, state: ParallelColumnUIState) {
        let ordered = members[id] ?? []
        guard let newest = ordered.last else { state.activityMembers.removeAll(); return }
        if let first = ordered.firstIndex(where: { state.activityMembers.contains($0) }) {
            state.activityMembers = Set(ordered[first...])
        } else {
            state.activityMembers = [newest]
        }
    }

    func revision(for conversationID: String) -> Int { states[conversationID]?.paginationRevision ?? 0 }

    @discardableResult func loadOlder(_ conversationID: String) -> Bool {
        guard canRequest(conversationID), errors[conversationID] == nil else { return false }
        guard let member = revealedMembers(conversationID).reversed().first(where: { histories[$0]?.hasMore == true }) else {
            if let previous = members[conversationID]?.last(where: { !isRevealed($0, conversationID: conversationID) }) {
                states[conversationID]?.activityMembers.insert(previous)
                states[conversationID]?.paginationRevision &+= 1
                onChange(previous)
                return true
            }
            return inventory.loadOlder(conversationID)
        }
        return request(member, conversationID: conversationID)
    }

    @discardableResult func retryOlder(_ conversationID: String) -> Bool {
        guard visible.contains(conversationID) else { return false }
        errors[conversationID] = nil
        if let member = revealedMembers(conversationID).first(where: { useCase.observation(for: $0).history.availableActions.contains(.retryRead) }) {
            return request(member, conversationID: conversationID, action: .retryRead)
        }
        return loadOlder(conversationID)
    }

    private func canRequest(_ id: String) -> Bool {
        let ids = members[id] ?? []
        return visible.contains(id) && !ids.isEmpty && requests[id] == nil && !inventory.isLoading(id)
            && ids.allSatisfy { leaseIDs[$0] != nil }
            && revealedMembers(id).allSatisfy { histories[$0]?.isLoading != true }
    }

    @discardableResult private func request(_ memberID: String, conversationID: String, action: EventObservationAction = .loadEarlier) -> Bool {
        let frame = useCase.observation(for: memberID)
        let history = frame.presentationHistory
        guard frame.history.availableActions.contains(action), !history.isLoading else {
            rejectRequest(memberID, conversationID: conversationID, history: history)
            return false
        }
        requests[conversationID] = Request(memberID: memberID, generation: history.generation)
        guard useCase.requestObservation(action, for: memberID, scope: frame.scope) else {
            requests[conversationID] = nil
            rejectRequest(memberID, conversationID: conversationID, history: useCase.observation(for: memberID).presentationHistory)
            return false
        }
        onChange(memberID)
        return true
    }

    private func rejectRequest(_ memberID: String, conversationID: String, history: EventHistoryState) {
        histories[memberID] = history
        if !(restoreTargets[conversationID] ?? [:]).isEmpty {
            stopRestoration(conversationID, error: "Older activity could not be loaded. Retry to continue.")
        }
        onChange(memberID)
    }

    private func historyChanged(_ memberID: String, history: EventHistoryState) {
        guard let id = owners[memberID] else { return }
        let previous = histories[memberID]
        histories[memberID] = history
        if var request = requests[id], request.memberID == memberID {
            if history.isLoading {
                request.observedLoading = true
                requests[id] = request
            } else if request.observedLoading || request.generation != history.generation {
                settle(request, conversationID: id, history: history)
            }
        }
        if requests[id] == nil { advanceRestoration(id) }
        if previous != history { onChange(memberID) }
    }

    private func settle(_ request: Request, conversationID: String, history: EventHistoryState) {
        requests[conversationID] = nil
        states[conversationID]?.paginationRevision &+= 1
        if let error = history.error {
            stopRestoration(conversationID, error: error)
        }
        onChange(request.memberID)
    }

    private func advanceRestoration(_ id: String) {
        guard canRequest(id), let targets = restoreTargets[id], !targets.isEmpty else { return }
        for memberID in members[id] ?? [] where targets[memberID] != nil {
            guard let target = targets[memberID], let history = histories[memberID] else { continue }
            let availability = useCase.observation(for: memberID).presentationAvailability
            if availability == .loading { return }
            if let error = history.error { stopRestoration(id, error: error); return }
            restoreGenerations[memberID] = history.generation
            let frame = useCase.observation(for: memberID)
            guard target.hasPrefix(frame.scope.identity + ":") else {
                // A newly acquired local scope cannot satisfy an old logical-row target.
                // Keep the retained reading boundary until explicit window replacement.
                stopRestoration(id, error: nil)
                return
            }
            if useCase.observation(for: memberID).items.contains(where: { useCase.observation(for: memberID).scope.identity + ":" + String($0.id) == target }) {
                restoreTargets[id]?[memberID] = nil
            } else if history.hasMore {
                request(memberID, conversationID: id)
                return
            } else {
                restoreTargets[id]?[memberID] = nil
            }
        }
        if let memberID = members[id]?.first { onChange(memberID) }
    }

    private func stopRestoration(_ id: String, error: String?) {
        restoreTargets[id] = nil
        errors[id] = error
    }

    private func rememberBoundary(_ memberID: String, conversationID: String) {
        let frame = useCase.observation(for: memberID)
        guard let first = frame.items.first, let state = states[conversationID] else { return }
        if let retained = state.oldestSequences[memberID],
           !frame.items.contains(where: { frame.scope.identity + ":" + String($0.id) == retained }) { return }
        state.oldestSequences[memberID] = frame.scope.identity + ":" + String(first.id)
    }

    func adoptCurrentWindow(_ id: String, frames: [String: EventObservationFrame]) {
        restoreTargets[id] = nil
        requests[id] = nil
        errors[id] = nil
        for memberID in members[id] ?? [] {
            restoreGenerations[memberID] = nil
            guard let frame = frames[memberID] else { continue }
            histories[memberID] = frame.presentationHistory
            states[id]?.oldestSequences[memberID] = frame.items.first.map { frame.scope.identity + ":" + String($0.id) }
        }
    }
}
