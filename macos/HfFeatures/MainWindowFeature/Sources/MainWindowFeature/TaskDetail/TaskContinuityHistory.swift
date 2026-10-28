import MonitorCore

// MARK: - TaskContinuityHistory

@MainActor
protocol TaskContinuityHistory: AnyObject {
    func record(_ observation: TaskSupervision.RestartObservation?, for taskID: String)
    func observations(for taskID: String) -> [TaskSupervision.RestartObservation]
}

/// Coordinator-session memory, scoped to exact task IDs; never writes engine state.
@MainActor
final class TaskContinuityHistoryStore: TaskContinuityHistory {
    private var history: [String: [TaskSupervision.RestartObservation]] = [:]
    private var order: [String] = []

    func record(_ observation: TaskSupervision.RestartObservation?, for taskID: String) {
        guard let observation else { return }
        var entries = history[taskID] ?? []
        guard !entries.contains(where: {
            $0.previousServer == observation.previousServer && $0.observerKind == observation.observerKind
                && $0.observingProcess == observation.observingProcess
        }) else { return }
        entries.append(observation)
        if history[taskID] == nil { order.append(taskID) }
        history[taskID] = Array(entries.suffix(32))
        if order.count > 256 { history.removeValue(forKey: order.removeFirst()) }
    }

    func observations(for taskID: String) -> [TaskSupervision.RestartObservation] { history[taskID] ?? [] }
}
