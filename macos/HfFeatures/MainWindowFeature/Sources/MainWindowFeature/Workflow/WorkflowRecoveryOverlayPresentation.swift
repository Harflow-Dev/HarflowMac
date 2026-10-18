import Foundation

// MARK: - WorkflowRecoveryOverlayPresentation

/// Pure local visibility and lifetime state for the non-blocking recovery overlay (the user
/// amendment over SPEC §6.4). It lives in view state only — never in the VM — and owns exactly
/// one lifetime question: whether each run ID has already received its one automatic open.
/// Keys are internal run IDs, never question or decision strings, so polling replacements and
/// checkpoint refreshes of the same run can never mint a second automatic presentation. A
/// recreated screen creates a fresh instance, which is the definition of "a new first load".
struct WorkflowRecoveryOverlayPresentation: Equatable {
    /// Run IDs whose first eligible loaded presentation already opened the panel automatically.
    /// An empty run ID never consumes a key, so a record without an ID can never block a later
    /// real one.
    private(set) var autoPresentedRunIDs: Set<String> = []
    /// The currently eligible run, distinct from the set of runs already auto-presented.
    private(set) var currentRunID: String?
    /// The panel's explicit visibility. Actual visibility additionally requires the current
    /// run to be eligible (see `eligibleRunID`), so an ineligible or disappeared run hides the
    /// panel without touching anything else.
    private(set) var isOpen = false
    /// An explicit-open editor focus request. Automatic presentation never sets it, so the
    /// first load never steals keyboard focus; only the eligible badge's open action does.
    private(set) var isEditorFocusRequested = false

    /// Visibility belongs to the current eligible run, even before lifecycle reconciliation.
    func isVisible(runID: String?) -> Bool {
        runID != nil && currentRunID == runID && isOpen
    }

    /// The one eligibility gate, shared by the badge and the panel: the run surface must be
    /// loaded (`initialLoadingKind == nil`, not failed), the currently selected run must be a
    /// non-builder run with a nonempty ID, and the existing
    /// `WorkflowRecoveryPresentation.showsRecovery(run)` must hold. Child, caller-owned and
    /// builder runs are ineligible exactly as before — no status is rewritten.
    static func eligibleRunID(run: WorkflowRunModel?, initialLoadingKind: String?, initialLoadFailed: Bool) -> String? {
        guard initialLoadingKind == nil, !initialLoadFailed,
              let run, !run.isBuilder, !run.id.isEmpty,
              WorkflowRecoveryPresentation.showsRecovery(run) else { return nil }
        return run.id
    }

    /// Reconciles lifetime state with the current eligibility. A first eligible loaded
    /// presentation of an unseen run ID opens the panel once; an ineligible, disappeared or
    /// ownership-changed run closes it. Switching to a run already shown closes it, while polling
    /// the same currently eligible run preserves its visibility and explicit focus request.
    /// A second attention checkpoint after Resume never reopens, and one run's
    /// open panel never outlives a run change. The honest eligible badge remains the
    /// discovery path for every later presentation.
    mutating func syncEligibility(runID: String?) {
        guard let runID, !runID.isEmpty else {
            currentRunID = nil
            isOpen = false
            isEditorFocusRequested = false
            return
        }
        guard currentRunID != runID else { return }
        currentRunID = runID
        isOpen = false
        isEditorFocusRequested = false
        autoPresentIfNeeded(runID: runID)
    }

    /// Opens the panel once at the first eligible loaded presentation of a nonempty, unseen run
    /// ID. Identical polling replacements, question/decision refreshes, resize and clock
    /// updates cannot reach this with a new key; a previously presented run ID never reopens
    /// automatically. Never requests editor focus.
    mutating func autoPresentIfNeeded(runID: String?) {
        guard let runID, !runID.isEmpty, !autoPresentedRunIDs.contains(runID) else { return }
        currentRunID = runID
        autoPresentedRunIDs.insert(runID)
        isOpen = true
    }

    /// The eligible badge's open action: open-only, never a toggle — activating it while the
    /// panel is already open leaves it open. Only this path requests editor focus, and the
    /// native focus system stays free to decline it.
    mutating func openFromBadge() {
        isOpen = true
        isEditorFocusRequested = true
    }

    /// Explicit dismissal: presentation only. Instructions, additional attempts, selection and
    /// every business state are untouched; the badge focus return is the caller's best-effort
    /// follow-up, never part of this state.
    mutating func closeExplicitly() {
        isOpen = false
        isEditorFocusRequested = false
    }
}
