import Foundation

// MARK: - M05StateTable

/// The M05 task-state matrix, as data: every state the suites render, the design route and file it answers to, and every
/// approved state the matrix deliberately does not render. `M05StateTableTests` checks this table for internal consistency; it
/// does not establish pixel fidelity or read the design repository.
enum M05StateTable {

    /// The HarflowDesign commit the state ids, copy and routes were read from.
    static let designCommit = "4ff7d83"

    /// The five matrix suites.
    enum Suite: String, CaseIterable {
        case status = "M05StatusStateMatrixHostedTests"
        case actionsTopBar = "M05ActionsTopBarStateMatrixHostedTests"
        case pane = "M05PaneStateMatrixHostedTests"
        case changes = "M05ChangesStateMatrixHostedTests"
        case transcript = "M05TranscriptStateMatrixHostedTests"
    }

    /// One rendered state.
    struct Entry: Equatable {
        let id: String
        let suite: Suite
        let designFile: String
        /// What the matrix does to reach the state.
        let recipe: String
        /// Set when native copy or structure differs from the design for this state; the matrix asserts what native renders.
        let deviation: String?
        /// Set only for a state the matrix lists but does not mount.
        let notRenderable: String?

        var designRoute: String { "task/" + id }
    }

    private static let proposal = "v2/scripts/screens-m05-proposal.js"
    private static let transcriptFile = "v2/scripts/screens-transcript.js"
    private static let loadingFile = "v2/scripts/screens-loading-work.js"
    private static let registryFile = "v2/scripts/registry.js"

    private static func entry(_ id: String, _ suite: Suite, file: String = proposal, _ recipe: String,
                              deviation: String? = nil, notRenderable: String? = nil) -> Entry {
        Entry(id: id, suite: suite, designFile: file, recipe: recipe, deviation: deviation, notRenderable: notRenderable)
    }

    /// Every state the suites mount (`notRenderable == nil`), plus the approved states the matrix lists without mounting.
    static let all: [Entry] = status + actions + pane + changes + transcript

    static let status: [Entry] = [
        entry("running-stop", .status, "running task, alive owner"),
        entry("stop-requested", .status, "real VM with an acknowledged stop request"),
        entry("cancelled", .status, "cancelled task with a matching snapshot and exit code"),
        entry("timed-out", .status, "timed_out task with a matching snapshot and exit code"),
        entry("settling", .status, "completed task, capture_settling changes, published observation"),
        entry("unknown-failed", .status, "failed task without an exit code, incomplete log"),
        entry("unknown-done", .status, "completed task reconstructed from closing output"),
        entry("owner-lost", .status, "running task, owner_state dead"),
        entry("unverified", .status, "running task, owner_state undecidable"),
        entry("launch-unknown", .status, "continuation fixture, ctl timed out after Continue"),
        entry("status-unavailable", .status, "status read answers no task after a good read"),
        entry("taken-over", .status, "cancelled task with taken_over"),
        entry("continue-starting", .status, "continuation fixture, ctl held pending"),
        entry("continue-started", .status, "continuation fixture, accepted"),
        entry("continue-refused", .status, "continuation fixture, engine refusal"),
        entry("failed-continue", .status, "failed task with exit code 1")
    ]

    static let actions: [Entry] = [
        entry("overflow-running", .actionsTopBar, "running task, More menu opened from the toolbar",
              deviation: "Native item titles carry no ellipsis (Take over in terminal, Open in terminal, Stop task); the design draws ellipses."),
        entry("overflow-settled", .actionsTopBar, "done task, pane on Changes, More menu opened",
              deviation: "Native item titles carry no ellipsis (Open in terminal); the design draws ellipses."),
        entry("overflow-subtask", .actionsTopBar, "running task spawned by a parent, More menu opened"),
        entry("stop-dialog", .actionsTopBar, "running task, stop confirmation sheet presented"),
        entry("stop-dialog-earlier-turns", .actionsTopBar, "running task with an earlier running turn, stop confirmation"),
        entry("takeover-dialog", .actionsTopBar, "running task, takeover confirmation requested"),
        entry("topbar-facts", .actionsTopBar, "pane open on Events with the notices group expanded"),
        entry("topbar-resource", .actionsTopBar, "running task holding heavy-build"),
        entry("topbar-minimum", .actionsTopBar, "1000x620, long title, widest badge, resource return")
    ]

    static let pane: [Entry] = [
        entry("pane-overlay", .pane, "done task, Changes open, 1000x620 only"),
        entry("pane-split", .pane, "done task, Changes open, 1280x800 only"),
        entry("pane-running-closed", .pane, "running task, no open choice"),
        entry("pane-running-open", .pane, "running task, pane open on Events"),
        entry("pane-failed-closed", .pane, "failed task, no open choice"),
        entry("events-populated", .pane, "done task with enforcement and notices, Events open"),
        entry("events-page", .pane, "observation frame offering Load earlier"),
        entry("events-page-error", .pane, "observation frame offering Retry history read",
              deviation: "The design draws the heading \"Earlier records couldn't be read\" and the action "
                  + "\"Reload from newest\"; native has neither and offers \"Retry history read\"."),
        entry("events-loading", .pane, "observation frame still loading"),
        entry("events-empty", .pane, "empty observation window",
              deviation: "The design draws \"No rows in the available captured history\" and "
                  + "\"An empty window does not qualify totals.\"; native has neither."),
        entry("events-error", .pane, "observation frame with unavailable history")
    ]

    static let changes: [Entry] = [
        entry("changes-single", .changes, "one repository listing"),
        entry("changes-multi", .changes, "eight repositories"),
        entry("changes-multi-limited", .changes, "eight repositories, one limited"),
        entry("changes-same-path", .changes, "same path in both scopes"),
        entry("changes-row-states", .changes, "binary, untracked, truncated, omitted and not captured rows"),
        entry("changes-incomplete", .changes, "incomplete capture with rows"),
        entry("changes-not-captured", .changes, "not captured per repository and scope"),
        entry("changes-unmerged", .changes, "unmerged_unknown and reported conflicts"),
        entry("changes-running", .changes, "running task, pending capture"),
        entry("changes-zero", .changes, "complete capture with zero rows"),
        entry("changes-no-repository", .changes, "no repository recorded"),
        entry("changes-text", .changes, "one diff read in chunks"),
        entry("changes-loading", .changes, "first read in flight"),
        entry("changes-error", .changes, "stored document unavailable"),
        entry("changes-turns", .changes, "continuation members")
    ]

    static let transcript: [Entry] = [
        entry("transcript-observed", .transcript, file: transcriptFile, "qualified observation with rows"),
        entry("transcript-loading", .transcript, file: transcriptFile, "observation frame still loading"),
        entry("transcript-partial", .transcript, file: transcriptFile, "known loss and partial request text"),
        entry("transcript-unavailable", .transcript, file: transcriptFile, "observation unavailable"),
        entry("transcript-integrity-failed", .transcript, file: transcriptFile, "request integrity failure"),
        entry("transcript-reconnecting", .transcript, file: transcriptFile, "reconnecting with retained rows"),
        entry("transcript-capacity", .transcript, file: transcriptFile, "reading window at capacity"),
        entry("transcript-sources", .transcript, file: transcriptFile, "normalized rows with a recovered stub"),
        entry("loading", .transcript, file: loadingFile, "real VM that has not listed"),
        entry("loading-pane", .transcript, file: loadingFile, "real VM that has not listed, pane open",
              notRenderable: "The skeleton has no pane; the right pane and its Events toggle are not drawn while the task is loading."),
        entry("approval", .transcript, file: registryFile, "pending caller approval at the feed tail")
    ]

    /// Approved states the matrix does not mount, each with the reason. Also listed in `all` when they belong to a suite
    /// (`loading-pane`); otherwise only here.
    static let exclusions: [(id: String, reason: String)] = [
        ("pending", "No task record exists, so the standalone view never mounts; the native equivalent is the Pending launches destination."),
        ("events-not-started", "Needs a pending launch with no task record; not reachable from the in-task shell."),
        ("loading-pane", "The skeleton has no pane; the right pane and its Events toggle are not drawn while the task is loading."),
        ("cancelled-partial", "Provisional design state; outside this matrix."),
        ("artifacts-populated", "Provisional design state; outside this matrix."),
        ("artifacts-page-error", "Provisional design state; outside this matrix."),
        ("artifacts-empty", "Provisional design state; outside this matrix."),
        ("artifacts-loading", "Provisional design state; outside this matrix."),
        ("artifacts-error", "Provisional design state; outside this matrix.")
    ]

    /// Provisional design families the matrix does not cover at all.
    static let excludedFamilies: [(prefix: String, reason: String)] = [
        ("message-", "Provisional message states; outside this matrix."),
        ("approval-", "Provisional approval states (exact, stale, refused, expired, answered elsewhere, uncertain); outside this matrix."),
        ("pending-", "Pending launches are a separate destination; a possible later matrix.")
    ]

    /// Every approved state id this matrix accounts for, rendered or excluded: the design's approved list.
    static let approved: Set<String> = Set(all.map(\.id)).union(exclusions.map(\.id))

    /// The entry for a state id.
    static func lookup(_ id: String) -> Entry? { all.first { $0.id == id } }

    /// The state ids a suite mounts.
    static func ids(_ suite: Suite) -> [String] { all.filter { $0.suite == suite && $0.notRenderable == nil }.map(\.id) }
}
