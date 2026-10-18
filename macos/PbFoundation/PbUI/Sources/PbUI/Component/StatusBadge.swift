import MonitorCore
import SwiftUI

// MARK: - StatusBadgeTint

/// The status badge's colour family: one tint per drawn state, mapped once here so every badge
/// surface agrees. `foreground` is the label/icon colour, `background` the capsule fill.
public enum StatusBadgeTint: Equatable, Sendable {
    /// Running and settling: `runningFG` on `runningBG`.
    case running
    /// Done: `doneGreen` on `doneBG`.
    case done
    /// Needs attention: `warningFG` on `warningBG`.
    case warning
    /// Failed and timed out: `failedRed` on `dangerBG`.
    case danger
    /// Pending and cancelled: `cancelledGray` on `neutralFill`.
    case pending
    /// An unknown raw status: `secondaryText` on `neutralFill`, never guessed into a state.
    case unknown

    public var foreground: Color {
        switch self {
        case .running: .runningFG
        case .done: .doneGreen
        case .warning: .warningFG
        case .danger: .failedRed
        case .pending: .cancelledGray
        case .unknown: .secondaryText
        }
    }

    public var background: Color {
        switch self {
        case .running: .runningBG
        case .done: .doneBG
        case .warning: .warningBG
        case .danger: .dangerBG
        case .pending, .unknown: .neutralFill
        }
    }
}

// MARK: - StatusBadgePresentation

/// A badge's tested presentation: its indicator (spinner or SF Symbol), its label and its tint.
/// Pure and `Sendable` so the mapping from a `TaskStatus` is testable without rendering.
public struct StatusBadgePresentation: Equatable, Sendable {
    /// `spinner` draws `RunningSpinner`; `symbol` draws the named SF Symbol.
    public enum Indicator: Equatable, Sendable {
        case spinner
        case symbol(String)
    }

    public let indicator: Indicator
    public let label: String
    public let tint: StatusBadgeTint

    public init(indicator: Indicator, label: String, tint: StatusBadgeTint) {
        self.indicator = indicator
        self.label = label
        self.tint = tint
    }
}

// MARK: - StatusBadge

/// The one shared status capsule (SPEC §5.1): icon, label and an optional elapsed time, 24 pt high
/// with 10 pt horizontal padding, on the state's tint. One VoiceOver element: it announces the
/// mapped state label plus the supplied elapsed time and taken-over annotation, and its decorative
/// children (the spinner and its own "Running" label) are ignored — a settling badge says
/// "Settling", never "Running", and a running badge never says it twice.
public struct StatusBadge: View {
    public let status: TaskStatus
    /// A caller-supplied, already-formatted elapsed string (monospaced digits, medium weight).
    /// The live clock stays with the caller — `StatusPill` owns its tick.
    public var elapsedText: String?
    /// Adds a visible and spoken "taken over" annotation when a person took the session over.
    public var isTakenOver: Bool
    /// A caller-supplied presentation that overrides the shared status mapping — the workflow
    /// run header's honest mapping (starting/settling/paused/cancelling) is the intended caller.
    /// The default `nil` keeps every existing task/menu mapping unchanged; an override never
    /// changes `TaskStatus`, a domain classification, or any action eligibility.
    public var presentationOverride: StatusBadgePresentation?

    public init(
        status: TaskStatus,
        elapsedText: String? = nil,
        isTakenOver: Bool = false,
        presentationOverride: StatusBadgePresentation? = nil
    ) {
        self.status = status
        self.elapsedText = elapsedText
        self.isTakenOver = isTakenOver
        self.presentationOverride = presentationOverride
    }

    /// The pure status → presentation mapping (SPEC §5.1): raw `pending`/`queued` read as Pending,
    /// `needs_input`/`needs_attention` (case- and underscore-insensitive) as Needs attention, and
    /// `settling` keeps its honest "Settling" label on a spinner. Any other raw status keeps its
    /// raw label on the dashed-circle unknown treatment — a visual mapping never changes
    /// `TaskStatus`, a domain classification, or task eligibility.
    public nonisolated static func presentation(for status: TaskStatus) -> StatusBadgePresentation {
        switch status {
        case .running:
            StatusBadgePresentation(indicator: .spinner, label: status.label, tint: .running)
        case .completed:
            StatusBadgePresentation(indicator: .symbol("checkmark"), label: status.label, tint: .done)
        case .failed, .timedOut:
            // Timed out keeps its distinct label; both share the failed styling.
            StatusBadgePresentation(indicator: .symbol("xmark"), label: status.label, tint: .danger)
        case .cancelled:
            StatusBadgePresentation(indicator: .symbol("stop.fill"), label: status.label, tint: .pending)
        case let .other(raw):
            switch raw.lowercased().replacingOccurrences(of: "_", with: " ") {
            case "settling":
                StatusBadgePresentation(indicator: .spinner, label: "Settling", tint: .running)
            case "pending", "queued":
                StatusBadgePresentation(indicator: .symbol("circle"), label: "Pending", tint: .pending)
            case "needs input", "needs attention":
                StatusBadgePresentation(indicator: .symbol("exclamationmark.triangle.fill"), label: "Needs attention", tint: .warning)
            default:
                StatusBadgePresentation(indicator: .symbol("circle.dashed"), label: raw, tint: .unknown)
            }
        }
    }

    /// The complete spoken string: the mapped state label, then the elapsed time, then the
    /// taken-over annotation — each part only when supplied.
    public nonisolated static func accessibilityLabel(
        stateLabel: String,
        elapsedText: String?,
        isTakenOver: Bool
    ) -> String {
        var parts = [stateLabel]
        if let elapsedText { parts.append(elapsedText) }
        if isTakenOver { parts.append("taken over") }
        return parts.joined(separator: ", ")
    }

    /// The resolved presentation: a caller-supplied override when one is given, otherwise the
    /// shared status mapping. Pure and `nonisolated` so the override contract is testable.
    public nonisolated static func effectivePresentation(
        for status: TaskStatus,
        override: StatusBadgePresentation?
    ) -> StatusBadgePresentation {
        override ?? presentation(for: status)
    }

    private var presentation: StatusBadgePresentation {
        Self.effectivePresentation(for: status, override: presentationOverride)
    }

    private var accessibilityText: String {
        Self.accessibilityLabel(stateLabel: presentation.label, elapsedText: elapsedText, isTakenOver: isTakenOver)
    }

    public var body: some View {
        HStack(spacing: PbRadius.Metrics.spacing6) {
            switch presentation.indicator {
            case .spinner:
                RunningSpinner(size: PbRadius.Metrics.badgeGlyphSize)
            case let .symbol(name):
                Image(systemName: name)
                    .font(.pb(.secondary))
            }
            Text(presentation.label)
            if let elapsedText {
                Text(elapsedText)
                    .monospacedDigit()
                    .fontWeight(.medium)
            }
            if isTakenOver {
                Text("taken over")
            }
        }
        .font(.pb(.secondary, weight: .semibold))
        .foregroundStyle(presentation.tint.foreground)
        .padding(.horizontal, PbRadius.Metrics.badgeHorizontalPadding)
        .frame(minHeight: PbRadius.Metrics.badgeHeight)
        .background(Capsule().fill(presentation.tint.background))
        // One element: the decorative spinner's own "Running" label never leaks into the
        // announcement, so Settling is not spoken as Running and Running is not spoken twice.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }
}

#if DEBUG
private struct StatusBadgesPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
            HStack(spacing: PbRadius.Metrics.spacing8) {
                StatusBadge(status: .running, elapsedText: "1:30")
                StatusBadge(status: .completed, elapsedText: "6:52")
                StatusBadge(status: .failed)
            }
            HStack(spacing: PbRadius.Metrics.spacing8) {
                StatusBadge(status: .timedOut)
                StatusBadge(status: .cancelled)
                StatusBadge(status: .other("pending"))
            }
            HStack(spacing: PbRadius.Metrics.spacing8) {
                StatusBadge(status: .other("needs_attention"))
                StatusBadge(status: .other("settling"))
                StatusBadge(status: .other("mystery-state"))
            }
            HStack(spacing: PbRadius.Metrics.spacing8) {
                StatusBadge(status: .completed, elapsedText: "6:52", isTakenOver: true)
            }
        }
        .padding()
        .background(Color.windowBG)
    }
}

#Preview("StatusBadge - light") { StatusBadgesPreview().preferredColorScheme(.light) }
#Preview("StatusBadge - dark") { StatusBadgesPreview().preferredColorScheme(.dark) }

#Preview("StatusBadge - unknown & Reduce Motion") {
    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
        StatusBadge(status: .other("unknown"))
        StatusBadge(status: .running, elapsedText: "0:42")
        StatusBadge(status: .other("settling"))
    }
    .padding()
    .background(Color.windowBG)
    .environment(\.pbReduceMotionOverride, true)
}

private struct WorkflowStatusBadgesPreview: View {
    var body: some View {
    // The workflow run header's honest mapping, delivered through the same shared capsule.
    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
        StatusBadge(status: .other("starting"), presentationOverride: StatusBadgePresentation(
            indicator: .spinner, label: "Starting", tint: .running))
        StatusBadge(status: .other("paused"), presentationOverride: StatusBadgePresentation(
            indicator: .symbol("exclamationmark.triangle.fill"), label: "Paused", tint: .warning))
        StatusBadge(status: .other("cancelling"), presentationOverride: StatusBadgePresentation(
            indicator: .symbol("stop.fill"), label: "Cancelling…", tint: .pending))
        StatusBadge(status: .other("running"), elapsedText: "1:30", presentationOverride: StatusBadgePresentation(
            indicator: .spinner, label: "Running", tint: .running))
    }
    .padding()
    .background(Color.windowBG)
    }
}

#Preview("Workflow status override - light") {
    WorkflowStatusBadgesPreview().preferredColorScheme(.light)
}

#Preview("Workflow status override - dark") {
    WorkflowStatusBadgesPreview().preferredColorScheme(.dark)
}

#Preview("Workflow status override - Reduce Motion") {
    WorkflowStatusBadgesPreview().preferredColorScheme(.dark).environment(\.pbReduceMotionOverride, true)
}
#endif
