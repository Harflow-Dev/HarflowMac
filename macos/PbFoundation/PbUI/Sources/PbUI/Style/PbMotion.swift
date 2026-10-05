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
}

// MARK: - ContentFadeIn

private struct ContentFadeIn: ViewModifier {
    @State private var appeared: Bool

    init(animate: Bool) {
        _appeared = State(initialValue: !animate)
    }

    func body(content: Content) -> some View {
        content
            .opacity(appeared ? 1 : 0)
            .onAppear {
                guard !appeared else { return }
                withAnimation(PbMotion.arrival) { appeared = true }
            }
    }
}

public extension View {
    /// Fades a newly mounted view once; stable identity keeps streaming updates fully visible.
    func pbFadeIn(animate: Bool = true) -> some View {
        modifier(ContentFadeIn(animate: animate))
    }
}
