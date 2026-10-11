import SwiftUI

// MARK: - PbMotion

/// Short, consistent motion for Monitor disclosures and content arrivals.
public enum PbMotion {
    /// Disclosure movement is replaced by a short opacity change under Reduce Motion.
    public static func disclosure(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    /// Fade-only arrivals avoid competing with live scrolling and pagination anchors.
    public static let arrival = Animation.easeOut(duration: 0.18)

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
    @Entry var pbReduceMotionOverride: Bool?
}

// MARK: - ContentFadeIn

private struct ContentFadeIn: ViewModifier {
    @State private var appeared: Bool

    init(animate: Bool) {
        _appeared = State(initialValue: !animate)
    }

    func body(content: Content) -> some View {
        content
            .animation(PbMotion.arrival) { view in
                view.opacity(appeared ? 1 : 0)
            }
            .onAppear {
                guard !appeared else { return }
                appeared = true
            }
    }
}

public extension View {
    /// Fades a newly mounted view once; stable identity keeps streaming updates fully visible.
    func pbFadeIn(animate: Bool = true) -> some View {
        modifier(ContentFadeIn(animate: animate))
    }
}
