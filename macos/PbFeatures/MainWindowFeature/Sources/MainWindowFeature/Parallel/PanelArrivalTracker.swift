import Foundation
import SwiftUI

// MARK: - PanelArrivalTracker

/// Establishes a loaded baseline, then marks new conversations rather than resumed task IDs.
struct PanelArrivalTracker {
    private var baseline: Date?
    private var seen: Set<String> = []
    private var arrivals: Set<String> = []

    mutating func didPresent(_ id: String) { arrivals.remove(id) }

    mutating func update(_ panels: [(id: String, startedAt: Date?)], authoritative: Bool, now: Date = Date()) -> Set<String> {
        guard authoritative else { return [] }
        let ids = Set(panels.map(\.id))
        guard let baseline else {
            baseline = now
            seen = ids
            return []
        }
        for panel in panels where !seen.contains(panel.id) {
            // Paged or resolved history predates opening this screen and never enters as new work.
            if let start = panel.startedAt, start >= baseline { arrivals.insert(panel.id) }
        }
        seen.formUnion(ids)
        return arrivals.intersection(ids)
    }
}

// MARK: - PanelArrival

struct PanelArrival: ViewModifier {
    @State private var animate: Bool
    init(animate: Bool) { _animate = State(initialValue: animate) }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = false

    func body(content: Content) -> some View {
        content.opacity(!animate || reduceMotion || visible ? 1 : 0)
            .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { visible = true } }
    }
}
