import HfRepository

// MARK: - ParallelWindowAdoption

/// Retained reading windows require explicit replacement when reacquisition creates a new local scope.
@MainActor
final class ParallelWindowAdoption {
    private var awaitingReplacement: Set<String> = []
    private var accepted: [String: EventObservationScope] = [:]
    private var unavailableReplacement: Set<String> = []
    private var capacityReplacement: Set<String> = []
    private(set) var pending: Set<String> = []

    func needsAdoption(id: String, previous: ParallelColumnInput?, frames: [String: EventObservationFrame]) -> Bool {
        guard let previous else { return false }
        let blocked = previous.members.contains { member in
            guard let frame = frames[member.task.taskID] else { return false }
            return frame.history.currentness == .sourceChangePending && !frame.history.availableActions.contains(.adoptCurrentSource)
        }
        if blocked { unavailableReplacement.insert(id) } else { unavailableReplacement.remove(id) }
        let capacity = previous.members.contains { frames[$0.task.taskID]?.history.availableActions.contains(.rebaseWindow) == true }
        if capacity { capacityReplacement.insert(id) } else { capacityReplacement.remove(id) }
        if awaitingReplacement.contains(id) {
            let current = previous.members.compactMap { frames[$0.task.taskID] }
            if current.count == previous.members.count, current.allSatisfy({ $0.history.currentness == .current && !$0.history.isLoading }) {
                adopt(id: id, frames: frames, members: Set(current.map(\.taskID)))
            } else { return true }
        }
        let changed = previous.members.contains { member in
            guard let frame = frames[member.task.taskID], let old = member.observation?.scope else { return false }
            return frame.scope != (accepted[member.task.taskID] ?? old) || frame.history.currentness == .sourceChangePending
                || frame.history.availableActions.contains(.rebaseWindow)
        }
        if changed { pending.insert(id) }
        return pending.contains(id)
    }

    func adopt(id: String, frames: [String: EventObservationFrame], members: Set<String>) {
        for member in members { accepted[member] = frames[member]?.scope }
        pending.remove(id)
        awaitingReplacement.remove(id)
    }

    func willReplace(id: String) { awaitingReplacement.insert(id) }

    func prepareColumn(_ column: inout ParallelColumnModel, id: String, adopt: @escaping () -> Void) {
        guard pending.contains(id) else { return }
        column.cachedHistoryNotice = "Observation session changed · cached history is not current. Replace this window to load current activity."
        if capacityReplacement.contains(id) {
            column.cachedHistoryNotice = "This view's activity limit has been reached. "
                + "Retained rows and reading position are preserved until you replace this window."
        }
        if unavailableReplacement.contains(id) {
            column.cachedHistoryNotice = "Current activity is unavailable because this observation's recovery limit has been reached. "
                + "Cached history is not current."
            column.onAdoptWindow = nil
        } else { column.onAdoptWindow = adopt }
        column.liveStep = nil
        column.stepCountText = nil
        column.noToolCallsText = nil
        column.isLoading = false
        column.history = .init()
    }

    func reset() {
        awaitingReplacement.removeAll()
        accepted.removeAll()
        unavailableReplacement.removeAll()
        capacityReplacement.removeAll()
        pending.removeAll()
    }
}
