import Foundation
import HfRepository
import HfUI
import MonitorCore

// MARK: - PendingLaunchDetailInput

/// VM-held action state the detail mapping needs besides the owner's stored lookup. The detail shows
/// only a lookup whose `selection` equals this selection exactly.
struct PendingLaunchDetailInput: Equatable, Sendable {
    let selection: PendingLaunchSelection
    var flags = PendingLaunchDetailFlags()
}

/// The VM-held part of the detail mapping.
struct PendingLaunchDetailFlags: Equatable, Sendable {
    /// True once the first check for this selection has finished (even when it stored nothing).
    var firstCheckSettled = false
    var handoffFailed = false
    /// A check, recorded-status call or Stop preparation is in flight or queued on the lease.
    var isBusy = false
    /// Stop preparation or submission was refused locally for the selection ("Stop was not sent").
    var stopPrepareNotSent = false
    /// The latest Stop attempt was acknowledged by an explicit Check again that stored a fresh lookup.
    var acknowledgedAttempt = false
    /// Check again was tapped since the last not-sent attempt, so the not-sent line is not repeated.
    var notSentCleared = false
}

// MARK: - PendingLaunchDetailPresentation

/// The selected launch's detail, prepared off the main actor. The view derives no launch semantics.
struct PendingLaunchDetailPresentation: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case checking, waiting, preparing, preparingHandshake, granted, notStarted
        case unavailable, missing, recorded, handoffFailed
        /// Outcome cards of a Stop attempt.
        case stopRequested, stopUncertain, stopRefused, stopDidNotStart
    }

    enum StopControl: Equatable, Sendable {
        case enabled, disabled
    }

    enum Action: Equatable, Sendable {
        case checkAgain, checkTaskStatus
    }

    struct Fact: Equatable, Sendable, Identifiable {
        let label: String
        let value: String
        /// Drawn in the monospaced face (identifiers).
        let isCode: Bool
        var id: String { label }
    }

    let kind: Kind
    let title: String
    let message: String
    let facts: [Fact]
    /// Nil only for the checking placeholder, which offers no action.
    let action: Action?
    let isActionEnabled: Bool
    /// The Stop button; nil hides it.
    var stop: StopControl?
    /// Lines between the action row and the detail note, in drawn order.
    var notes: [String] = []

    static let note = "Harflow has not confirmed a running task yet. Messages and activity remain unavailable."
    static let checkingLabel = "Checking launch status"

    /// The state shown from the instant a row is selected until the first build replaces it.
    static func checking(taskID: String) -> Self {
        .init(kind: .checking, title: checkingLabel, message: "", facts: [selectedID(taskID)], action: nil, isActionEnabled: false)
    }

    static func selectedID(_ taskID: String) -> Fact { .init(label: "Selected ID", value: taskID, isCode: true) }
}

// MARK: - Mapping

extension PendingLaunchDetailPresentation {
    /// What the owner stored for the selected ID.
    enum Evidence: Equatable, Sendable {
        case none, failed
        case value(TaskPendingLaunchLookup)
    }

    /// Only a lookup whose selection equals the current one is evidence; anything else is ignored.
    static func make(
        lookup: PendingLaunchLookup?, input: PendingLaunchDetailInput, stop: PendingLaunchStopProjection? = nil,
        runtimeKnown: Bool = false, timeZone: TimeZone = .autoupdatingCurrent
    ) -> Self {
        let evidence: Evidence = if let lookup, lookup.selection == input.selection {
            lookup.failure == nil ? lookup.value.map(Evidence.value) ?? .failed : .failed
        } else {
            .none
        }
        return make(taskID: input.selection.taskID, evidence: evidence, flags: input.flags, stop: stop, runtimeKnown: runtimeKnown,
                    timeZone: timeZone)
    }

    /// Total mapping from the exactly-matching evidence. Unrecognized or contradictory inputs never
    /// upgrade to a more confident state.
    static func make(
        taskID: String, evidence: Evidence, flags: PendingLaunchDetailFlags, stop: PendingLaunchStopProjection? = nil,
        runtimeKnown: Bool = false, timeZone: TimeZone = .autoupdatingCurrent
    ) -> Self {
        let status: Self = switch evidence {
        case .none: flags.firstCheckSettled ? unavailable(taskID, flags) : checking(taskID: taskID)
        case .failed: unavailable(taskID, flags)
        case .value(let value): make(taskID: taskID, item: value.item, flags: flags, timeZone: timeZone)
        }
        return withStop(status, taskID: taskID, evidence: evidence,
                        context: .init(flags: flags, stop: stop, runtimeKnown: runtimeKnown, timeZone: timeZone))
    }

    private static func make(taskID: String, item: TaskPendingLaunchItem, flags: PendingLaunchDetailFlags, timeZone: TimeZone) -> Self {
        switch item.disposition {
        case .notFound:
            return simple(.missing, "Launch not found",
                          "This ID was not found in the latest check. It may have started or changed elsewhere. Its outcome is unknown.",
                          taskID, flags)
        case .recorded:
            if flags.handoffFailed {
                return simple(.handoffFailed, "Task status unavailable",
                              "Harflow found a task, but could not check its status. Task controls remain unavailable.", taskID, flags)
            }
            return simple(.recorded, "Task record found", "Harflow found a task with this ID. Check its status to open it.",
                          taskID, flags, action: .checkTaskStatus)
        case .pending:
            guard let launch = item.launch else { return unavailable(taskID, flags) }
            return qualified(launch, item: item, flags: flags, timeZone: timeZone)
        case .refused, .unknown, .unrecognized:
            return unavailable(taskID, flags)
        }
    }

    private static func qualified(
        _ launch: TaskPendingLaunchMetadata, item: TaskPendingLaunchItem, flags: PendingLaunchDetailFlags, timeZone: TimeZone
    ) -> Self {
        let facts = qualifiedFacts(launch, taskID: item.taskID, timeZone: timeZone)
        let confirmation = "Harflow has not confirmed a running task yet."
        let kind: Kind, title: String, message: String
        switch launch.state {
        case .waitingForResources:
            (kind, title) = (.waiting, "Waiting for resources")
            let resources = joinedResources(launch.resourceNames)
            message = resources.map { "Waiting for \($0). \(confirmation)" } ?? confirmation
        case .reserved, .claimed:
            if item.cancelSupport == .unsupported {
                (kind, title) = (.preparingHandshake, "Preparing · Stop unavailable")
                message = "This engine cannot stop this preparation yet. Stop becomes available after Harflow confirms the task has started."
            } else {
                (kind, title) = (.preparing, "Preparing")
                message = "Harflow is preparing this launch. A running task has not been confirmed yet."
            }
        case .granted:
            (kind, title) = (.granted, "Launch granted")
            message = "The engine granted this launch. \(confirmation)"
        case .notStarted:
            (kind, title) = (.notStarted, "Did not start")
            message = notStartedMessage(launch.notStartedReason)
        case .unrecognized:
            return unavailable(item.taskID, flags)
        }
        return .init(kind: kind, title: title, message: message, facts: facts, action: .checkAgain, isActionEnabled: !flags.isBusy)
    }

    static func qualifiedFacts(_ launch: TaskPendingLaunchMetadata, taskID: String, timeZone: TimeZone) -> [Fact] {
        var facts = [Fact(label: "Launch ID", value: taskID, isCode: true)]
        if let backend = trimmed(launch.backend) {
            facts.append(.init(label: "Harness", value: BackendStyle.displayName(backend), isCode: false))
        }
        // Trimming only detects a blank value: the delivered path is shown unchanged.
        if let repository = launch.repoPath, trimmedText(repository) != nil {
            facts.append(.init(label: "Repository", value: repository, isCode: false))
        }
        if let created = launch.createdAt.flatMap(trimmedText).flatMap(ISODate.parse) {
            facts.append(.init(label: "Created", value: createdText(created, timeZone: timeZone), isCode: false))
        }
        let resources = launch.resourceNames.isEmpty ? "None requested" : launch.resourceNames.joined(separator: " · ")
        facts.append(.init(label: "Resources", value: resources, isCode: false))
        return facts
    }

    private static func unavailable(_ taskID: String, _ flags: PendingLaunchDetailFlags) -> Self {
        simple(.unavailable, "Launch status unavailable", "Harflow could not check this launch. Its outcome is unknown.", taskID, flags)
    }

    static func simple(_ kind: Kind, _ title: String, _ message: String, _ taskID: String, _ flags: PendingLaunchDetailFlags,
                       action: Action = .checkAgain) -> Self {
        .init(kind: kind, title: title, message: message, facts: [selectedID(taskID)], action: action, isActionEnabled: !flags.isBusy)
    }

    // MARK: - Variable copy

    /// English list join without `ListFormatter`: "A", "A and B", "A, B and C". Nil when empty.
    static func joinedResources(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: names[0]
        default: names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    static func notStartedMessage(_ reason: String?) -> String {
        let base = "The engine recorded that this launch did not start."
        guard let reason = trimmed(reason) else { return base }
        return base + reasonSentence(reason)
    }

    /// " Reason: {reason}." with a single terminal period.
    static func reasonSentence(_ reason: String) -> String {
        " Reason: \(reason.hasSuffix(".") || reason.hasSuffix("…") ? reason : reason + ".")"
    }

    /// Fixed English shape `d MMM yyyy, HH:mm` in the given zone (the app is English-only). Formatters are cached
    /// per zone: builds run concurrently off the main actor and a configured `DateFormatter` is safe to share.
    static func createdText(_ date: Date, timeZone: TimeZone) -> String {
        formatters.withLock { cache in
            if let cached = cache[timeZone] { return cached.string(from: date) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = "d MMM yyyy, HH:mm"
            cache[timeZone] = formatter
            return formatter.string(from: date)
        }
    }

    private static let formatters = FormatterCache()

    private static func trimmed(_ value: String?) -> String? { value.flatMap(trimmedText) }

    private static func trimmedText(_ value: String) -> String? {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }
}

// MARK: - FormatterCache

private final class FormatterCache: @unchecked Sendable {
    private let lock = NSLock()
    private var formatters: [TimeZone: DateFormatter] = [:]

    func withLock<Value>(_ body: (inout [TimeZone: DateFormatter]) -> Value) -> Value {
        lock.withLock { body(&formatters) }
    }
}
