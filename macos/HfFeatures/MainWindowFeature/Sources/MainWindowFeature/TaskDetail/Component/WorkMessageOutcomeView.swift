import AppKit
import HfUI
import SwiftUI

// MARK: - WorkMessageOutcomeView

/// A static transcript row with a programmatic focus target, excluded from ordinary Tab traversal.
struct WorkMessageOutcomeView: View {
    let text: String
    var focusToken: UUID?
    var consumeFocus: (UUID) -> Bool = { _ in false }

    var body: some View {
        Text(text)
            .font(TaskScreenStyle.sans(size: 12))
            .lineSpacing(TaskScreenStyle.lineSpacing(.init(size: 12, lineHeight: 17)))
            .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            .background(WorkMessageOutcomeFocusProbe(text: text, token: focusToken, consume: consumeFocus))
    }
}

struct WorkMessageOutcomeFocusProbe: NSViewRepresentable {
    let text: String
    let token: UUID?
    let consume: (UUID) -> Bool

    func makeNSView(context _: Context) -> WorkMessageOutcomeFocusTarget { WorkMessageOutcomeFocusTarget() }

    func updateNSView(_ view: WorkMessageOutcomeFocusTarget, context _: Context) {
        view.setAccessibilityElement(true)
        view.setAccessibilityRole(.staticText)
        view.setAccessibilityLabel(text)
        view.setAccessibilityIdentifier("message-outcome")
        guard let token else { return }
        DispatchQueue.main.async { [weak view] in
            // Consume even in the background. Returning to the app is not a new action.
            let current = consume(token)
            guard current, let view, NSApp.isActive, let window = view.window, window.isKeyWindow else { return }
            guard window.makeFirstResponder(view) else { return }
            view.setAccessibilityFocused(true)
            NSAccessibility.post(element: view, notification: .focusedUIElementChanged)
        }
    }
}

final class WorkMessageOutcomeFocusTarget: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { false }
}

#if DEBUG
#Preview("Message cancelled outcome") {
    WorkMessageOutcomeView(text: "Queued message cancelled.").padding().frame(width: 420)
}
#endif
