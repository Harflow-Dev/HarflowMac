import Combine
import Foundation
import HfRepository
import MonitorCore

// MARK: - TaskContinuationPresentation

/// Complete render inputs for the approved standalone Continue states (Design 6e31cd7).
struct TaskContinuationPresentation: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case eligible, starting, accepted, refused, unknown }
    let taskID: String
    let phase: Phase
    var attemptID: UUID?
    var exitCode: Int?
    var status: TaskStatus
    var message: String?
    var canContinue = false
    var canCheck = false
    var isChecking = false
    var locksActions = false

    var title: String {
        switch phase {
        case .starting, .eligible:
            switch status {
            case .failed: exitCode.map { "Task failed: the harness exited with code \($0)" } ?? "Task failed"
            case .cancelled: "Cancelled"
            case .timedOut: "This run stopped at its turn limit"
            default: phase == .starting ? "Starting a new session…" : "Task finished"
            }
        case .accepted: "New session accepted"
        case .refused: "Continue was refused"
        case .unknown: "A new session may have started"
        }
    }

    var body: String {
        switch phase {
        case .accepted: "The engine accepted the request. It may still be waiting for resources; acceptance does not mean completion."
        case .refused: "The engine refused this request."
        case .unknown: "The engine did not report back after Continue, so a task may exist. Don't resend yet."
        case .starting: ""
        case .eligible:
            switch status {
            case .cancelled: "Files already written stay in place. Harflow did not undo anything."
            case .timedOut: "Timed out here means the limit on turns, not a clock. Files already written stay in place."
            default: ""
            }
        }
    }
}

// MARK: - TaskContinuationSession

/// Mounted read lifecycle only. Submitted mutations belong to the shared repository.
@MainActor
final class TaskContinuationSession {
    var submittedRequest: TaskContinuationRequest?
    var runtime: QualificationRuntimeToken?
    var taskID: String?
    var generation = UUID()
    var statusRevision: UInt64?
    var supported = false
    var supportRead: Task<Void, Never>?
    var observation: AnyCancellable?
    var adoptionRead: Task<Void, Never>?
    var checkedGoals: Set<String> = []
    var observedAttempts: Set<UUID> = []
}
