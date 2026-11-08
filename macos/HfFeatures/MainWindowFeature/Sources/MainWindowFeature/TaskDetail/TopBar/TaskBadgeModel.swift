//
//  TaskBadgeModel.swift
//  MainWindowFeature
//
//  The standalone top bar's status badge as plain values: what the badge says, which icon and colour pair it
//  uses and how its clock behaves. The mapping is a pure function of `TaskSnapshotEvidence`, so every claim a
//  qualifier makes comes from a status snapshot of the status shown, never from a listing row.
//  Design reference: HarflowDesign 17739e4, `m05-proposal.js` BADGES.
//

import Foundation
import HfUI
import MonitorCore

// MARK: - TaskBadgeModel

/// What the top bar's status badge draws.
struct TaskBadgeModel: Equatable, Sendable {

    /// The badge's leading indicator.
    enum Icon: Equatable, Sendable {
        /// The 10 point running spinner.
        case spinner
        /// A 12 point SF Symbol.
        case symbol(String)
    }

    /// The `TaskScreenStyle.Badge` colour pair the badge uses.
    enum Tone: Equatable, Sendable {
        case running, done, failed, attention, warning, neutral
        /// Transparent, keeping the base foreground.
        case plain
    }

    /// The elapsed time shown after the label.
    enum Clock: Equatable, Sendable {
        /// No time is shown.
        case none
        /// A live clock counting from this start; ticks inside the badge view only.
        case live(Date)
        /// A recorded duration.
        case fixed(TimeInterval)
    }

    let icon: Icon
    let tone: Tone
    /// The words, without the clock: "Running", "Done · exit not observed".
    let label: String
    let clock: Clock
    /// Words after the clock: "· taken over".
    let suffix: String?

    /// The spoken text for a badge with a fixed or no clock. A live badge is not spoken from this: its clock child
    /// supplies the elapsed time, so the value is current whenever VoiceOver reads it.
    func accessibilityText(clock text: String?) -> String {
        [label, text, suffix].compactMap(\.self).joined(separator: ", ")
    }

    /// Whether `status` is a pending task, whose top bar shows neither meta nor an access chip.
    nonisolated static func isPending(_ status: TaskStatus) -> Bool {
        guard case let .other(raw) = status else { return false }
        return ["pending", "queued"].contains(raw.lowercased())
    }

    // MARK: - Mapping

    /// The badge for `evidence`. Precedence: taken over, owner warnings, inferred exit qualifiers, plain status.
    nonisolated static func make(evidence: TaskSnapshotEvidence, startedAt: Date?) -> TaskBadgeModel {
        let status = evidence.status
        let plain = plainBadge(evidence: evidence, startedAt: startedAt)
        if evidence.takenOver {
            return TaskBadgeModel(icon: .symbol(Symbols.stop), tone: .neutral, label: status.label, clock: plain.clock,
                                  suffix: "· taken over")
        }
        if status.isRunning, evidence.hasMatchingSnapshot {
            switch evidence.ownerState {
            case "dead": return warning("Running · owner lost")
            case "undecidable": return warning("Running · not verified")
            default: break
            }
        }
        if evidence.hasMatchingSnapshot, evidence.exitCode == nil {
            if status == .completed {
                return TaskBadgeModel(icon: .symbol(Symbols.check), tone: .done, label: "Done · exit not observed", clock: .none, suffix: nil)
            }
            if status == .failed, evidence.logState == .incomplete {
                return TaskBadgeModel(icon: .symbol(Symbols.cross), tone: .failed, label: "Failed · exit not observed", clock: .none, suffix: nil)
            }
        }
        return plain
    }

    private static func warning(_ label: String) -> TaskBadgeModel {
        TaskBadgeModel(icon: .symbol(Symbols.alert), tone: .warning, label: label, clock: .none, suffix: nil)
    }

    /// The plain status badge, with the clock only a matching snapshot supports.
    private static func plainBadge(evidence: TaskSnapshotEvidence, startedAt: Date?) -> TaskBadgeModel {
        let settled = evidence.settledDuration.map(Clock.fixed) ?? .none
        switch evidence.status {
        case .running:
            return TaskBadgeModel(icon: .spinner, tone: .running, label: "Running", clock: startedAt.map(Clock.live) ?? .none, suffix: nil)
        case .completed:
            return TaskBadgeModel(icon: .symbol(Symbols.check), tone: .done, label: "Done", clock: settled, suffix: nil)
        case .failed:
            return TaskBadgeModel(icon: .symbol(Symbols.cross), tone: .failed, label: "Failed", clock: settled, suffix: nil)
        case .timedOut:
            return TaskBadgeModel(icon: .symbol(Symbols.clock), tone: .failed, label: "Timed out", clock: settled, suffix: nil)
        case .cancelled:
            return TaskBadgeModel(icon: .symbol(Symbols.stop), tone: .neutral, label: "Cancelled", clock: settled, suffix: nil)
        case .other:
            let presentation = StatusBadge.presentation(for: evidence.status)
            let icon: Icon = switch presentation.indicator {
            case .spinner: .spinner
            case let .symbol(name): .symbol(name)
            }
            let tone: Tone = switch presentation.tint {
            case .running: .running
            case .done: .done
            case .warning: .attention
            case .danger: .failed
            case .pending: .neutral
            case .unknown: .plain
            }
            return TaskBadgeModel(icon: icon, tone: tone, label: presentation.label, clock: .none, suffix: nil)
        }
    }

    /// The SF Symbols the badge uses.
    private enum Symbols {
        static let check = "checkmark"
        static let cross = "xmark"
        static let stop = "stop.fill"
        static let alert = "exclamationmark.triangle.fill"
        static let clock = "clock"
    }
}
