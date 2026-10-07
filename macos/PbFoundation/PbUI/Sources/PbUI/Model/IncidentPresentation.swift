import Foundation
import Observation
import PbCommon

// MARK: - IncidentPresentation

/// Retains actionable failures separately from the transient notification.
@Observable @MainActor
public final class IncidentPresentation {
    /// A failure with a stable source and message identity.
    public struct Incident: Identifiable, Equatable {
        public let source: String
        public let message: String
        public var retry: AlertAction?
        public var id: String { source + "\n" + message }
    }

    public private(set) var current: Incident?
    public private(set) var failures: [Incident] = []
    public private(set) var remaining: TimeInterval = 8
    private var identities: [String: String] = [:]
    private var previousTick: Date?
    public init() {}

    @discardableResult
    public func report(source: String, message: String, retry: AlertAction? = nil) -> Bool {
        let incident = Incident(source: source, message: message, retry: retry)
        guard identities[source] != incident.id else {
            // A fresh read can have the same failure but a new operation-bound retry action.
            // Refresh only that action: preserve arrival order, dismissal and active display time.
            if let index = failures.firstIndex(where: { $0.id == incident.id }) { failures[index].retry = retry }
            if current?.id == incident.id { current?.retry = retry }
            return false
        }
        identities[source] = incident.id
        failures.removeAll { $0.source == source }
        failures.append(incident)
        current = incident
        remaining = 8
        previousTick = nil
        return true
    }

    public func resolve(source: String) {
        identities.removeValue(forKey: source)
        failures.removeAll { $0.source == source }
        if current?.source == source { dismiss() }
    }

    public func dismiss() { current = nil; previousTick = nil }

    /// Counts active display time only; deterministic timestamps make timing behavior testable.
    public func tick(now: Date, paused: Bool) {
        guard current != nil else { previousTick = nil; return }
        defer { previousTick = now }
        guard !paused, let previousTick else { return }
        remaining -= max(0, now.timeIntervalSince(previousTick))
        if remaining <= 0 { dismiss() }
    }
}
