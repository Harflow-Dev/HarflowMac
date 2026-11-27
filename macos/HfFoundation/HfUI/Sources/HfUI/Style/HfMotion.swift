import SwiftUI

// MARK: - HfMotion

/// Short, consistent motion for Monitor disclosures and content arrivals.
public enum HfMotion {
    /// Disclosure movement is replaced by a short opacity change under Reduce Motion.
    public static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    /// Fade-only arrivals avoid competing with live scrolling and pagination anchors.
    public static let arrival = Animation.easeOut(duration: arrivalDuration)

    /// Duration of a content arrival, in seconds. Shared with arrivals drawn in Core Animation
    /// (an ease-out layer animation of the same length), so both read as one motion.
    public static let arrivalDuration: Double = 0.18

    /// How a presentation component resolves Reduce Motion: an explicit `override` wins over the
    /// system setting, `nil` follows it. The system value is read-only, so this is how previews,
    /// fixtures and tests drive motion deterministically — never a user-visible setting.
    public static func reduceMotion(override: Bool?, system: Bool) -> Bool {
        override ?? system
    }
}

// MARK: - Presentation motion override

public extension EnvironmentValues {
    /// Forces Monitor presentation motion (the running spinner, the segmented thumb) on or off
    /// (`nil`: follow the system Reduce Motion setting). Presentation-only: no VM publishes it,
    /// nothing persists it, and no feature setting reads or writes it.
    @Entry var hfReduceMotionOverride: Bool?

    /// Whether the window that owns this view tree is hidden (closed, miniaturised or fully covered),
    /// so its clock-driven views should stop producing frames. Written only by the main window's
    /// coordinator, and read by the clocks that sit in the window's root graph through `HfClockSchedule`.
    /// Default `false`: a surface that never sets it keeps ticking.
    @Entry var hfMotionPaused: Bool = false
}

// MARK: - HfClockSchedule

/// A `TimelineView` schedule that ticks every `interval` seconds, or yields nothing while `isPaused`.
///
/// The first entry is the date the view asks from, so a clock that resumes after a pause shows the
/// current time at once instead of waiting for the next period; the next entries follow every
/// `interval`. `TimelineView(.periodic)` has no `paused:` parameter, so this is the pausable form.
public struct HfClockSchedule: TimelineSchedule, Equatable, Sendable {
    /// Seconds between entries.
    public let interval: TimeInterval
    /// Whether the schedule currently yields no entries.
    public let isPaused: Bool

    public init(every interval: TimeInterval, paused: Bool = false) {
        self.interval = interval
        self.isPaused = paused
    }

    /// The entries: none while paused, else the start date followed by one entry per interval.
    public struct Entries: Sequence, IteratorProtocol, Sendable {
        fileprivate var upcoming: Date?
        fileprivate let interval: TimeInterval

        public mutating func next() -> Date? {
            guard let current = upcoming else { return nil }
            upcoming = current.addingTimeInterval(interval)
            return current
        }
    }

    public func entries(from startDate: Date, mode _: Mode) -> Entries {
        Entries(upcoming: isPaused ? nil : startDate, interval: interval)
    }
}

public extension TimelineSchedule where Self == HfClockSchedule {
    /// A once-a-second clock that stops while `paused`.
    static func hfSecond(paused: Bool) -> HfClockSchedule { HfClockSchedule(every: 1, paused: paused) }

    /// A once-a-minute clock that stops while `paused`.
    static func hfMinute(paused: Bool) -> HfClockSchedule { HfClockSchedule(every: 60, paused: paused) }
}

// MARK: - ContentFadeIn

private struct ContentFadeIn: ViewModifier {
    @Environment(\.hfSkeletonHandoffActive) private var handoffActive
    @State private var appeared: Bool

    init(animate: Bool) {
        _appeared = State(initialValue: !animate)
    }

    func body(content: Content) -> some View {
        content
            .animation(HfMotion.arrival) { view in
                view.opacity(appeared || handoffActive ? 1 : 0)
            }
            .onAppear {
                guard !appeared else { return }
                appeared = true
            }
    }
}

public extension View {
    /// Fades a newly mounted view once; stable identity keeps streaming updates fully visible.
    func hfFadeIn(animate: Bool = true) -> some View {
        modifier(ContentFadeIn(animate: animate))
    }
}
