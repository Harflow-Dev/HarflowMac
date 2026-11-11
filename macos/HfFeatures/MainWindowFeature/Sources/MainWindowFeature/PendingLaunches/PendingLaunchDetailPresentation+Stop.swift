import Foundation
import MonitorCore

// MARK: - Stop copy

extension PendingLaunchDetailPresentation {
    static let availabilityNote = "The engine may refuse Stop if this launch is controlled by a workflow or your access does not allow it."
    static let notSentNote = "Stop was not sent. Try again."
    static let unconfirmedNote =
        "Harflow will not send Stop again automatically. A missing launch or an unavailable status does not confirm that it stopped."
    static let requestedMessage = "The request was accepted. This does not confirm that the launch or task stopped. Check its status again."
    static let uncertainMessage =
        "The Stop response could not be confirmed. The launch or task may still be active. Check its state before taking another action."
    static let refusedMessage = "The engine refused Stop. The launch or task may still be active."
    static let didNotStartMessage = "The engine recorded that this launch did not start."
}

// MARK: - Eligibility

extension PendingLaunchDetailPresentation {
    /// Stop is offered only on Waiting, Preparing and Launch granted with a supported cancel mechanism and a known
    /// engine runtime. Mirrors `prepareStop`'s own guards, so the button never leads to a refusal the screen can see.
    static func stopEligibility(item: TaskPendingLaunchItem, runtimeKnown: Bool) -> Bool {
        guard runtimeKnown, item.disposition == .pending, !item.hasUnsupportedObservations,
              item.cancelSupport == .supported, let launch = item.launch else { return false }
        switch launch.state {
        case .waitingForResources, .reserved, .claimed, .granted: return true
        case .notStarted, .unrecognized: return false
        }
    }
}

// MARK: - StopContext

extension PendingLaunchDetailPresentation {
    /// Everything besides the status card that the Stop mapping reads.
    struct StopContext {
        var flags: PendingLaunchDetailFlags
        var stop: PendingLaunchStopProjection?
        var runtimeKnown: Bool
        var timeZone: TimeZone
    }
}

// MARK: - Mapping

extension PendingLaunchDetailPresentation {
    /// Adds the Stop button, its notes and the outcome cards to the slice-2 status mapping.
    static func withStop(_ status: Self, taskID: String, evidence: Evidence, context: StopContext) -> Self {
        let (flags, stop, runtimeKnown, timeZone) = (context.flags, context.stop, context.runtimeKnown, context.timeZone)
        let item: TaskPendingLaunchItem? = if case .value(let value) = evidence { value.item } else { nil }
        let launch = item.flatMap { $0.disposition == .pending ? $0.launch : nil }
        if let stop, let card = outcomeCard(stop.latest, taskID: taskID, launch: launch, flags: flags, timeZone: timeZone) { return card }
        guard status.kind != .checking else { return status }
        let eligible = item.map { stopEligibility(item: $0, runtimeKnown: runtimeKnown) } ?? false
        let generation = launch?.generation
        var control: StopControl?
        if eligible, let generation {
            if let latest = stop?.latest, latest.phase == .sending, latest.generation == generation {
                control = .disabled
            } else if stop?.unsafeGenerations.contains(generation) != true {
                control = flags.isBusy ? .disabled : .enabled
            }
        }
        var notes: [String] = []
        let notSentAttempt = stop?.latest.phase == .notSent && generation != nil && stop?.latest.generation == generation
        if flags.stopPrepareNotSent || (notSentAttempt && !flags.notSentCleared) { notes.append(notSentNote) }
        if control != nil { notes.append(availabilityNote) }
        if let stop, stop.hasUnconfirmed, !eligible || generation.map(stop.unconfirmedGenerations.contains) == true {
            notes.append(unconfirmedNote)
        }
        var result = status
        result.stop = control
        result.notes = notes
        return result
    }

    /// The card for a resolved attempt that has not been acknowledged and that the current lookup does not contradict.
    private static func outcomeCard(
        _ latest: PendingLaunchStopEvidence, taskID: String, launch: TaskPendingLaunchMetadata?,
        flags: PendingLaunchDetailFlags, timeZone: TimeZone
    ) -> Self? {
        guard !flags.acknowledgedAttempt, launch.map({ $0.generation == latest.generation }) ?? true else { return nil }
        let kind: Kind, title: String, message: String
        var notes: [String] = []
        switch latest.phase {
        case .requested:
            (kind, title, message) = (.stopRequested, "Stop requested", requestedMessage)
            notes = [unconfirmedNote]
        case .uncertain:
            (kind, title, message) = (.stopUncertain, "Stop outcome unknown", uncertainMessage)
            notes = [unconfirmedNote]
        case .refused(let reason):
            (kind, title) = (.stopRefused, "Stop refused")
            message = refusedMessage + (reason.map(reasonSentence) ?? "")
        case .didNotStart:
            (kind, title, message) = (.stopDidNotStart, "Did not start", didNotStartMessage)
        case .sending, .preflightChanged, .notSent: return nil
        }
        let facts = launch.map { qualifiedFacts($0, taskID: taskID, timeZone: timeZone) } ?? [selectedID(taskID)]
        return .init(kind: kind, title: title, message: message, facts: facts, action: .checkAgain, isActionEnabled: !flags.isBusy,
                     stop: nil, notes: notes)
    }
}
