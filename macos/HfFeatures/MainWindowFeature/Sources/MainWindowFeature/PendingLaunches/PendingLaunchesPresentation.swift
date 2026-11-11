import Foundation
import HfRepository
import HfUI
import MonitorCore

// MARK: - PendingLaunchesSource

/// What the subscription forwards. It is only a trigger: the view model re-reads the synchronous owner snapshot
/// to project. Stop attempts appear as a cheap fingerprint (identity and lifecycle, no engine text and no runtime
/// token), so a change in an attempt still triggers a reproject while the conversion to evidence happens only for
/// the selected ID, at projection time.
struct PendingLaunchesSource: Equatable, Sendable {
    struct AttemptFingerprint: Equatable, Sendable {
        let id: UUID
        let isExecuting: Bool
        let hasFailure: Bool
        let hasOutcome: Bool
    }

    var runtimeIdentity: UUID
    var runtimeKnown: Bool
    var inventory: PendingLaunchInventory
    var lookups: [PendingLaunchLookup]
    var attempts: [AttemptFingerprint]

    init(_ snapshot: PendingLaunchSnapshot) {
        self.runtimeIdentity = snapshot.runtimeIdentity
        self.runtimeKnown = snapshot.currentRuntime != nil
        self.inventory = snapshot.inventory
        self.lookups = snapshot.lookups
        self.attempts = snapshot.attempts.map {
            AttemptFingerprint(id: $0.id, isExecuting: $0.isExecuting, hasFailure: $0.preflightFailure != nil, hasOutcome: $0.outcome != nil)
        }
    }
}

// MARK: - PendingLaunchesProjection

/// The only snapshot fields the screen reads: runtime identity, whether the engine's runtime is known, the
/// inventory, the lookup stored for this view model's own lease and the selected ID's Stop attempts. Other
/// leases' lookups and attempts for other IDs publish distinct full snapshots with an unchanged projection,
/// which must not rebuild the presentation.
struct PendingLaunchesProjection: Equatable, Sendable {
    var runtimeIdentity: UUID
    var runtimeKnown: Bool
    var inventory: PendingLaunchInventory
    var lookup: PendingLaunchLookup?
    var stop: PendingLaunchStopProjection?

    init(runtimeIdentity: UUID, runtimeKnown: Bool = false, inventory: PendingLaunchInventory, lookup: PendingLaunchLookup? = nil,
         stop: PendingLaunchStopProjection? = nil) {
        self.runtimeIdentity = runtimeIdentity
        self.runtimeKnown = runtimeKnown
        self.inventory = inventory
        self.lookup = lookup
        self.stop = stop
    }

    /// Attempts are filtered to the engine's current runtime (matched by token equality, so returning to an earlier
    /// runtime restores its attempts; none while it is unknown) and to the selected ID before they are converted to
    /// token-free evidence. The token is never stored, displayed or logged.
    init(_ snapshot: PendingLaunchSnapshot, lease: PendingLaunchReadLease? = nil, selectedTaskID: String? = nil) {
        let evidence: [PendingLaunchStopEvidence] = if let selectedTaskID, let current = snapshot.currentRuntime {
            snapshot.attempts
                .filter { $0.confirmation.taskID == selectedTaskID && $0.confirmation.runtime == current }
                .map(PendingLaunchStopEvidence.init)
        } else {
            []
        }
        self.init(runtimeIdentity: snapshot.runtimeIdentity, runtimeKnown: snapshot.currentRuntime != nil, inventory: snapshot.inventory,
                  lookup: lease.flatMap { lease in snapshot.lookups.first { $0.selection.lease == lease } },
                  stop: selectedTaskID.flatMap { PendingLaunchStopProjection(evidence, taskID: $0) })
    }
}

// MARK: - PendingLaunchesPresentation

/// Values prepared off the main actor; the view derives no inventory semantics.
struct PendingLaunchesPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case inventory, loading, empty, failed, incomplete
    }

    enum CheckAction: Equatable, Sendable {
        case hidden, enabled, disabled
    }

    struct Row: Equatable, Sendable, Identifiable {
        /// The full launch ID; also the row identity.
        let id: String
        let title: String
        /// `Harness · Repository · State label`, each part omitted when unknown.
        let meta: String?
    }

    let kind: Kind
    let title: String
    let message: String
    let rows: [Row]
    let checkAction: CheckAction

    static let loading = PendingLaunchesPresentation(
        kind: .loading, title: "Checking pending launches",
        message: "Checking this engine for pending launches…", rows: [], checkAction: .hidden
    )
}

// MARK: - Mapping

extension PendingLaunchesPresentation {
    static let neutralRowTitle = "Pending launch"

    /// Total mapping from the owner's inventory evidence. Unknown or unrecognized inputs never
    /// upgrade to a more confident state: a lease refusal and every other failure show the failed
    /// copy, and only a completed check without failure can be empty. `didObserveRead` is true once this
    /// appearance has seen a read in flight: an idle inventory with no result after that (a read the
    /// owner abandoned as superseded) is failed rather than loading forever.
    static func make(
        _ projection: PendingLaunchesProjection, leaseRefused: Bool, didObserveRead: Bool = false
    ) -> PendingLaunchesPresentation {
        let inventory = projection.inventory
        let rows = inventory.rows.map(row)
        let action: CheckAction = inventory.isRefreshing ? .disabled : .enabled
        if leaseRefused { return failed(rows, action) }
        if let failure = inventory.failure {
            switch failure {
            case .incomplete, .requestBudget, .deadline: return incomplete(rows, action)
            default: return failed(rows, action)
            }
        }
        if inventory.completedCheck { return rows.isEmpty ? empty : listed(rows, action) }
        guard rows.isEmpty else { return listed(rows, action) }
        return inventory.isRefreshing || !didObserveRead ? loading : failed(rows, action)
    }

    private static func listed(_ rows: [Row], _ action: CheckAction) -> Self {
        .init(kind: .inventory, title: "Pending launches", message: "Select a launch to check its status.",
              rows: rows, checkAction: action)
    }

    private static let empty = PendingLaunchesPresentation(
        kind: .empty, title: "No pending launches observed",
        message: "No pending launches were found in this completed check. New launches may appear after this check.",
        rows: [], checkAction: .hidden
    )

    private static func failed(_ rows: [Row], _ action: CheckAction) -> Self {
        .init(kind: .failed, title: "Pending launches unavailable",
              message: "The engine could not be read. Pending launches may still exist.", rows: rows, checkAction: action)
    }

    private static func incomplete(_ rows: [Row], _ action: CheckAction) -> Self {
        .init(kind: .incomplete, title: "More launches may exist",
              message: "This check could not cover every launch. More launches may exist.", rows: rows, checkAction: action)
    }

    /// Only a pending row with qualified metadata shows harness, repository and state.
    static func row(_ item: TaskPendingLaunchItem) -> Row {
        guard item.disposition == .pending, let launch = item.launch else {
            return .init(id: item.taskID, title: neutralRowTitle, meta: nil)
        }
        let parts = [
            launch.backend.flatMap(trimmed).map(BackendStyle.displayName),
            launch.repoPath.flatMap(trimmed).flatMap(repositoryName),
            stateLabel(launch.state)
        ].compactMap(\.self)
        return .init(id: item.taskID, title: launch.title.flatMap(trimmed) ?? neutralRowTitle,
                     meta: parts.isEmpty ? nil : parts.joined(separator: " · "))
    }

    static func stateLabel(_ state: TaskPendingLaunchMetadata.State) -> String? {
        switch state {
        case .waitingForResources: "Waiting for resources"
        case .reserved, .claimed: "Preparing"
        case .granted: "Launch granted"
        case .notStarted: "Did not start"
        case .unrecognized: nil
        }
    }

    private static func trimmed(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func repositoryName(_ path: String) -> String? {
        path.split(separator: "/").last.flatMap { trimmed(String($0)) }
    }
}
