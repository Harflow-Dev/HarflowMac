import MonitorCore

// MARK: - WorkflowNodeExecutionSettings

/// Presentation of saved execution preferences; runtime compatibility remains authoritative.
enum WorkflowNodeExecutionSettings {
    static func canContinuePrevious(_ node: WorkflowNodeModel, definition: [String: JSONValue]) -> Bool {
        let incoming = WorkflowJSON.edges(definition).filter { $0.target == node.id && !$0.isBackward }
        guard incoming.count == 1,
              let source = WorkflowJSON.nodes(definition).first(where: { $0.id == incoming[0].source }),
              source.type == "agent" else { return false }
        return true
    }

    static func timeoutSeconds(_ node: WorkflowNodeModel) -> Int? {
        guard let seconds = node.raw["timeout_seconds"]?.intValue, seconds > 0 else { return nil }
        return seconds
    }
}

// MARK: - WorkflowTimeoutUnit

/// Display unit only. Saved workflow durations remain whole seconds.
enum WorkflowTimeoutUnit: String, CaseIterable {
    case seconds, minutes, hours

    var multiplier: Double {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours: 3600
        }
    }

    static func preferred(for seconds: Int) -> Self {
        if seconds.isMultiple(of: 3600) { return .hours }
        return seconds.isMultiple(of: 60) ? .minutes : .seconds
    }

    func value(for seconds: Int) -> Double { Double(seconds) / multiplier }

    /// Fractional durations round to the nearest whole second; invalid edits do not disable the limit.
    func seconds(for value: Double) -> Int? {
        guard value.isFinite, value > 0 else { return nil }
        let seconds = (value * multiplier).rounded()
        guard seconds.isFinite, (1 ... 86400).contains(seconds) else { return nil }
        return Int(seconds)
    }
}
