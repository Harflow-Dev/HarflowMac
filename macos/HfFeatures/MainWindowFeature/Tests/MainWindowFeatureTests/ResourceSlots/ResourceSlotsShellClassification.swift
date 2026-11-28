import Foundation

// MARK: - ResourceSlotsShellObservation

/// Everything the classification needs, gathered from the evidence after one variant ran.
struct ResourceSlotsShellObservation {
    struct Oracle {
        var ownerIsFirstResponder = false
        var stable = false
        var reopenedSameRow = false
        var reopenAttempted = false
    }

    /// A harness or reachability prerequisite that did not hold.
    var unexecuted: String?
    /// Untagged input the window's monitor saw.
    var outsideInput: [String] = []
    /// Production diagnostic increases during the return cycle.
    var authorized = 0
    var requests = 0
    var restored = 0
    var userMoved = 0
    var userCancel = 0
    var budget = 0
    var cancelSeq: Int?
    var gestureCompleteSeq: Int?
    var independentInputs: [String] = []
    /// Set when the delivery of the Back gesture's release could not be established.
    var gestureUnresolved: String?
    /// A posted release an earlier variant of this run could neither observe nor find in the queue.
    var priorLeakedEvent: String?
    /// Set when the responder transition inside the Back action differs from the variant's
    /// expected starting transition; not judged for the control variant.
    var startMismatch: String?
    /// Proxy-to-proxy responder transitions after authorization.
    var proxyToProxy: [String] = []
    /// Descriptive only: what the responder log showed between authorization and the cancellation.
    var transitionSummary = "no responder transition observed"
    var subtype = "no responder transition observed in the log"
    var oracle = Oracle()
}

// MARK: - ResourceSlotsShellVerdict

enum ResourceSlotsShellVerdict: Equatable {
    case passed
    case unexecuted(String)
    case outsideInput(String)
    case unresolved(String)
    case cancelledDuringBackGesture(String)
    case automaticCancellation(String)
    case budgetExhausted
    case unexplained(String)

    var isPass: Bool { self == .passed }

    var headline: String {
        switch self {
        case .passed: "Not reproduced (focus returned to the owner and stayed)"
        case let .unexecuted(reason): "Unexecuted: \(reason)"
        case let .outsideInput(detail): "Unresolved: outside input (\(detail))"
        case let .unresolved(detail): "Unresolved: \(detail)"
        case let .cancelledDuringBackGesture(detail): "Cancelled during the Back gesture (\(detail))"
        case let .automaticCancellation(subtype): "Automatic cancellation observed; mechanism unresolved (\(subtype))"
        case .budgetExhausted: "Restoration lost: budget"
        case let .unexplained(detail): "Unexplained restoration failure (product): \(detail)"
        }
    }
}

// swiftlint:disable cyclomatic_complexity
/// Evaluated in order: unexecuted, outside input, cancellation (during the gesture, or
/// automatic), budget, then the unexplained product failure. A subtype only describes what the
/// log observed; it never names a mechanism.
func resourceSlotsShellClassify(_ observation: ResourceSlotsShellObservation) -> ResourceSlotsShellVerdict {
    if let reason = observation.unexecuted { return .unexecuted(reason) }
    if !observation.outsideInput.isEmpty {
        if let leak = observation.priorLeakedEvent {
            return .unresolved("possible leaked test event (\(leak)); \(observation.outsideInput.count) untagged event(s): "
                + observation.outsideInput.prefix(5).joined(separator: ", "))
        }
        return .outsideInput("\(observation.outsideInput.count) untagged event(s): " + observation.outsideInput.prefix(5).joined(separator: ", "))
    }
    if let detail = observation.gestureUnresolved { return .unresolved(detail) }
    if !observation.independentInputs.isEmpty {
        return .unresolved("test contamination: input other than the Back gesture was sent between authorization and the terminal diagnostic: "
            + observation.independentInputs.joined(separator: ", "))
    }
    let cancelled = observation.userMoved > 0 || observation.userCancel > 0
    if cancelled {
        if let cancel = observation.cancelSeq, let complete = observation.gestureCompleteSeq, cancel < complete {
            return .cancelledDuringBackGesture(observation.transitionSummary)
        }
        return .automaticCancellation(observation.subtype)
    }
    if observation.budget > 0 { return .budgetExhausted }
    var problems: [String] = []
    if observation.authorized != 1 { problems.append("focus-authorized x\(observation.authorized)") }
    if observation.requests != 1 { problems.append("no single focus request (x\(observation.requests))") }
    if observation.restored != 1 { problems.append("no single completion (focus-restored x\(observation.restored))") }
    if let mismatch = observation.startMismatch { problems.append("starting transition: " + mismatch) }
    if !observation.proxyToProxy.isEmpty {
        problems.append("proxy-to-proxy transition after authorization: " + observation.proxyToProxy.joined(separator: "; "))
    }
    if !observation.oracle.ownerIsFirstResponder { problems.append("owner control is not the first responder") }
    if !observation.oracle.stable { problems.append("focus was lost after assignment") }
    if !observation.oracle.reopenedSameRow { problems.append(observation.oracle.reopenAttempted
        ? "Space did not reopen the same row" : "Space reopen not attempted") }
    return problems.isEmpty ? .passed : .unexplained(problems.joined(separator: "; "))
}

// swiftlint:enable cyclomatic_complexity
