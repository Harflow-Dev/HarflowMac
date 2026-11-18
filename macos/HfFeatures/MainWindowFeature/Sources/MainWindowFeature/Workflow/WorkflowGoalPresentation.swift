import Foundation
import MonitorCore

// MARK: - WorkflowGoalDraft

/// The unsent revision of a run goal, kept by the view model so every goal block of the run shares one draft.
struct WorkflowGoalDraft: Equatable, Sendable {
    /// Identifies one editing session; a save completion applies only to the session that submitted it.
    let sessionID: UUID
    let runID: String
    /// The goal revision the draft was opened on, sent as the engine's expected revision.
    var expectedRevision: Int
    var text: String
}

// MARK: - WorkflowGoalPresentation

/// The goal block's content for one run: label, text, assessment row and revision history.
struct WorkflowGoalPresentation: Equatable, Sendable {
    /// One earlier goal revision.
    struct HistoryEntry: Equatable, Sendable, Identifiable {
        let revision: Int
        let text: String
        var id: Int { revision }
    }

    /// Statuses after which a run no longer changes.
    static let terminalRunStatuses: Set<String> = ["completed", "failed", "cancelled", "blocked", "timed_out", "succeeded"]

    /// The run this content was derived from; a view uses it only for that run.
    let runID: String
    /// The run's goal revision in this projection; the card and header predicates compare against it.
    let goalRevision: Int
    let label: String
    let formLabel: String
    let text: String?
    let assessmentText: String?
    let assessmentReason: String?
    let evidenceRefs: [String]
    /// Earlier revisions, newest first; excludes the current revision.
    let history: [HistoryEntry]
    /// The engine's reason a revision is unavailable.
    let unavailableReason: String?

    init(run: WorkflowRunModel) {
        self.runID = run.id
        self.goalRevision = run.goalRevision
        let revision = run.goalRevision
        self.label = revision <= 1 ? "GOAL" : "Goal · revision \(revision)"
        self.formLabel = "Goal · revision \(max(1, revision))"
        self.text = run.goal
        let assessment = run.goalAssessment
        self.assessmentText = Self.assessmentText(assessmentStatus: assessment.map { $0["status"]?.stringValue ?? "unverifiable" },
                                             runStatus: run.status)
        self.assessmentReason = assessment?["reason"]?.stringValue
        self.evidenceRefs = (assessment?["evidence_refs"]?.arrayValue ?? []).compactMap(\.stringValue)
        self.history = run.goalHistory
            .map { HistoryEntry(revision: $0["revision"]?.intValue ?? 0, text: $0["goal"]?.stringValue ?? "") }
            .filter { $0.revision < revision }
            .sorted { $0.revision > $1.revision }
        self.unavailableReason = run.monitorReason("revise_goal") ?? run.goalRevisionReason
    }

    /// The assessment row copy, or nil when no row is shown. `assessmentStatus` is nil while the engine has written none.
    static func assessmentText(assessmentStatus: String?, runStatus: String) -> String? {
        let terminal = terminalRunStatuses.contains(runStatus)
        guard let assessmentStatus else {
            if ["running", "starting"].contains(runStatus) { return "Assessment: in progress" }
            if ["paused", "needs_input", "needs_attention"].contains(runStatus) { return "Assessment: not met yet" }
            return nil
        }
        switch assessmentStatus {
        case "satisfied": return "Assessment: met"
        case "unmet": return terminal ? "Assessment: not met" : "Assessment: not met yet"
        default: return "Assessment: unverifiable"
        }
    }

    /// Whether a run shows a goal block at all: it has a goal or accepts a revision.
    static func showsBlock(run: WorkflowRunModel) -> Bool {
        run.goal != nil || run.canReviseGoal
    }

    /// Whether the answered-elsewhere card replaces the block: a lost revise race stays shown only until the next revision.
    static func showsAnsweredElsewhere(outcomeAction: String?, expectedRevision: Int?, runRevision: Int) -> Bool {
        guard outcomeAction == "revise_goal", let expectedRevision else { return false }
        return runRevision == expectedRevision + 1
    }

    /// Whether the screen header drops the copy of a goal-revision outcome: only while a mounted goal block shows its card.
    static func suppressesHeaderOutcome(cardShown: Bool, isDefaultSidebarShown: Bool, selectedPaneShowsGoal: Bool) -> Bool {
        cardShown && (isDefaultSidebarShown || selectedPaneShowsGoal)
    }
}
