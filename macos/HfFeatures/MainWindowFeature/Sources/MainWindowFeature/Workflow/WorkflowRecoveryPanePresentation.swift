import Foundation
import MonitorCore

// MARK: - WorkflowRunSidebarSlot

/// What the run view's right-hand slot shows. One pure function drives what is drawn, the summary's
/// duplicate-question suppression and the Escape guard, so the three can never disagree.
enum WorkflowRunSidebarSlot: Equatable, Sendable {
    /// Graph, no node selected, recovery eligible: the run sidebar re-headed as the recovery pane.
    case recoveryPane
    /// The default run sidebar.
    case defaultSidebar
    /// Graph with a selected node: the selected-node pane.
    case selectedNode
    /// Parallel with an eligible run: the default sidebar plus the floating recovery overlay.
    case overlay

    /// The slot for the current view mode, recovery eligibility and node selection.
    static func resolve(isGraph: Bool, isRecoveryEligible: Bool, hasNodeSelection: Bool) -> Self {
        if isGraph {
            if hasNodeSelection { return .selectedNode }
            return isRecoveryEligible ? .recoveryPane : .defaultSidebar
        }
        return isRecoveryEligible ? .overlay : .defaultSidebar
    }

    /// The pane sizing the split view applies for this slot.
    var paneSizing: WorkflowRunPaneSizing {
        switch self {
        case .recoveryPane: .recovery
        case .selectedNode: .activity
        case .defaultSidebar, .overlay: .default
        }
    }

    /// Whether the run summary hides its copy of the recovery question: the pane in Graph, or a visible overlay in Parallel.
    func suppressesSummaryQuestion(overlayIsVisible: Bool) -> Bool {
        switch self {
        case .recoveryPane: true
        case .overlay: overlayIsVisible
        case .defaultSidebar, .selectedNode: false
        }
    }

    /// Whether Escape belongs to the visible overlay rather than clearing the node selection. The pane is not an overlay.
    func escapeBelongsToOverlay(overlayIsVisible: Bool) -> Bool {
        self == .overlay && overlayIsVisible
    }

    /// Whether the floating overlay is drawn at all; Graph never draws it.
    var allowsOverlay: Bool { self == .overlay }
}

// MARK: - WorkflowRecoveryFocusRequest

/// An incrementing editor focus request. Each activation of the badge issues a new token; the visible
/// editor consumes the pending one, so a second activation focuses again even when focus has moved on.
struct WorkflowRecoveryFocusRequest: Equatable, Sendable {
    private(set) var token = 0
    private(set) var consumed = 0

    /// Whether a request has been issued and not yet consumed.
    var isPending: Bool { token != consumed }

    /// Issues a new request.
    mutating func request() { token += 1 }

    /// Marks the current request handled; a no-op when none is pending.
    mutating func consume() { consumed = token }

    /// Drops a pending request without handling it, so an editor mounted later does not take focus.
    mutating func cancel() { consumed = token }
}

// MARK: - WorkflowRecoveryPanePresentation

/// Pure content rules of the recovery pane.
enum WorkflowRecoveryPanePresentation {
    /// The glyph before the failure sentence.
    enum Glyph: Equatable, Sendable {
        case failed
        case attention
    }

    /// The text shown when the engine reports no question.
    static let fallbackQuestion = "Scheduling is paused."
    static let instructionsPlaceholder = "Tell the next attempt what to do differently."

    /// The failed glyph when retries are exhausted or the run is a failed delegation, else the attention glyph.
    static func glyph(for run: WorkflowRunModel) -> Glyph {
        let hasExhaustedEdges = run.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false
        return hasExhaustedEdges || (run.isDelegation && run.status == "failed") ? .failed : .attention
    }

    /// The question line, or the fallback when the engine reports none.
    static func question(for run: WorkflowRunModel) -> String {
        run.question.isEmpty ? fallbackQuestion : run.question
    }
}
