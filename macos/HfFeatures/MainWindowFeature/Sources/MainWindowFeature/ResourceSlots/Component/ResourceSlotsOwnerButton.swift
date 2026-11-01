import AppKit
import Combine
import HfUI
import SwiftUI

// MARK: - ResourceSlotsOwnerFocusOperation

/// Owner focus is consumed through a single-use token, exactly like the qualified
/// CallerApproval focus operation: retries never time out inside the control, and the
/// reading state's 64-frame focus budget remains the only bound. Completion happens only
/// after `window.firstResponder === view` is verified under the same token.
@MainActor
private final class ResourceSlotsOwnerFocusOperation {
    /// The reading-state hooks an attempt consults, bundled to keep `configure` small.
    struct Hooks {
        var isReady: () -> Bool = { false }
        var authorizedResponder: () -> NSResponder? = { nil }
        var acknowledge: (UUID) -> Void = { _ in }
        var userMovedFocus: () -> Void = {}
    }

    private var token: UUID?
    private weak var view: NSView?
    private var hooks = Hooks()
    private var observation: AnyCancellable?
    private var attempt: Task<Void, Never>?
    private var attemptGeneration = UUID()

    var hasPendingRequest: Bool { token != nil }
    var currentToken: UUID? { token }

    func configure(token: UUID?, view: NSView, hooks: Hooks) {
        if self.token != token {
            attempt?.cancel()
            attempt = nil
            self.token = token
            observation = nil
        }
        self.view = view
        self.hooks = hooks
        guard token != nil else {
            observation = nil
            return
        }
        if observation == nil {
            observation = NotificationCenter.default
.publisher(for: NSWindow.didBecomeKeyNotification)
.merge(with: NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
.sink { [weak self] _ in
                    MainActor.assumeIsolated { self?.retry() }
                }
        }
        retry()
    }

    func cancel() {
        attempt?.cancel()
        attempt = nil
        observation = nil
        // A dismantled control neither reports a pending request (so it stops accepting
        // first responder status) nor retains the reading state through its hooks.
        token = nil
        hooks = Hooks()
    }

    func retry() {
        guard let token, attempt == nil else { return }
        let generation = UUID()
        attemptGeneration = generation
        attempt = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled, self.token == token else { return }
            defer { if attemptGeneration == generation { attempt = nil } }
            guard let view, let window = view.window,
                  window.isKeyWindow, NSApplication.shared.isActive,
                  !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
                  hooks.isReady() else { return }
            guard Self.isNeutral(window.firstResponder, of: view, authorized: hooks.authorizedResponder()) else {
                // Only a responder change after the Back authorization counts as user focus
                // movement; the returning owner never steals keyboard focus back.
                hooks.userMovedFocus()
                return
            }
            guard window.makeFirstResponder(view) else { return }
            await Task.yield()
            guard !Task.isCancelled, self.token == token, view.window === window,
                  window.isKeyWindow, window.firstResponder === view else { return }
            hooks.acknowledge(token)
        }
    }

    /// Neutral responders: none, the window, the control itself, an ancestor (the hosting
    /// view chain), or the responder captured at Back. Accepted limitation: with Full
    /// Keyboard Access on, SwiftUI-internal focus moves inside the hosting view are not
    /// observable as responder changes; the header toggle and scrolling already cancel
    /// restoration through `cancelRestorationForUser`.
    private static func isNeutral(_ responder: NSResponder?, of view: NSView, authorized: NSResponder?) -> Bool {
        guard let responder else { return true }
        if responder === view || responder === view.window { return true }
        if let authorized, responder === authorized { return true }
        var ancestor = view.superview
        while let current = ancestor {
            if current === responder { return true }
            ancestor = current.superview
        }
        return false
    }
}

// MARK: - ResourceSlotsOwnerButton

/// The design's owner "Open …" action as a real focusable AppKit control. The SwiftUI
/// `Button` + `@FocusState` pair is not keyboard-focusable with Full Keyboard Access off;
/// this control accepts `makeFirstResponder` and activates once on a real Space, following
/// the proven `ApprovalDecisionButton` pattern. Visuals reproduce `MonitorButtonStyle(.tinted)`:
/// a capsule `runningBG` fill with a semibold `.hf(.body)` `accentLink` title.
struct ResourceSlotsOwnerButton: NSViewRepresentable {
    let title: String
    /// The full accessibility label the old SwiftUI `.accessibilityLabel` carried: the action
    /// label plus the row title and ownerID. It is set on the button itself (never through a
    /// SwiftUI accessibility modifier on the representable), so the exposed control announces
    /// the exact action it performs.
    let label: String
    let identifier: String
    /// The appearance generation the reading state issued; the control reports it back with
    /// every focus observation so a superseded appearance's callback is recognisable.
    var generation: UUID?
    let token: UUID?
    let isReady: () -> Bool
    let authorizedResponder: () -> NSResponder?
    let acknowledge: (UUID) -> Void
    let observeFocusGain: (UUID?, UUID?) -> Void
    let observeFocusLoss: (UUID?, UUID?) -> Void
    let userMovedFocus: () -> Void
    let action: () -> Void

    func makeNSView(context: Context) -> Control {
        let button = Control(title: title, target: nil, action: nil)
        button.cell = Cell(textCell: title)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.isBordered = false
        button.focusRingType = .exterior
        button.target = button
        button.action = #selector(Control.invoke)
        return button
    }

    func updateNSView(_ button: Control, context: Context) {
        button.title = title
        button.isEnabled = context.environment.isEnabled
        button.setAccessibilityLabel(label)
        button.setAccessibilityIdentifier(identifier)
        button.performAction = action
        button.focusObservationGeneration = generation
        button.observeFocusGain = observeFocusGain
        button.observeFocusLoss = observeFocusLoss
        button.focus.configure(token: button.isEnabled ? token : nil, view: button,
                               hooks: .init(isReady: isReady, authorizedResponder: authorizedResponder,
                                            acknowledge: acknowledge, userMovedFocus: userMovedFocus))
    }

    func sizeThatFits(_: ProposedViewSize, nsView: Control, context _: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    static func dismantleNSView(_ view: Control, coordinator _: ()) {
        view.dismantle()
    }

    /// AppKit exposes the button cell as its accessible element in ordinary hosted windows, so
    /// every identity attribute the control owns is forwarded from `controlView`: without the
    /// forwarding the exposed cell reports an empty label and VoiceOver announces an unnamed
    /// button. Both the view and its cell carry the same label, so a label lookup still finds
    /// exactly this owner control.
    final class Cell: NSButtonCell {
        override func accessibilityLabel() -> String? {
            (controlView as? Control)?.accessibilityLabel() ?? super.accessibilityLabel()
        }

        override func accessibilityIdentifier() -> String {
            (controlView as? Control)?.accessibilityIdentifier() ?? super.accessibilityIdentifier()
        }

        /// The role-appropriate title of a push button is its visible action text.
        override func accessibilityTitle() -> String? {
            (controlView as? Control)?.title ?? super.accessibilityTitle()
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled, let button = controlView as? Control else { return false }
            return button.accessibilityPerformPress()
        }

        override func highlight(_ flag: Bool, withFrame cellFrame: NSRect, in controlView: NSView) {
            super.highlight(flag, withFrame: cellFrame, in: controlView)
            (controlView as? Control)?.setPressed(flag)
        }
    }

    @MainActor
    final class Control: NSButton {
        fileprivate let focus = ResourceSlotsOwnerFocusOperation()
        var performAction: () -> Void = {}
        var focusObservationGeneration: UUID?
        var observeFocusGain: (UUID?, UUID?) -> Void = { _, _ in }
        var observeFocusLoss: (UUID?, UUID?) -> Void = { _, _ in }
        /// Test-side hook serviced inside the cell's synchronous tracking loop when the
        /// pressed state changes; nil in production.
        var pressedObserver: (@MainActor (Bool) -> Void)?

        private var pressed = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focus.retry()
        }

        override func layout() {
            super.layout()
            focus.retry()
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override var acceptsFirstResponder: Bool {
            focus.hasPendingRequest || window?.firstResponder === self || NSApp.isFullKeyboardAccessEnabled
        }

        override var intrinsicContentSize: NSSize {
            let textSize = (title as NSString).size(withAttributes: [.font: Self.titleFont])
            return NSSize(width: ceil(textSize.width) + HfRadius.Metrics.secondaryButtonHorizontalPadding * 2,
                         height: max(HfRadius.Metrics.primaryButtonHeight, ceil(textSize.height)))
        }

        override var focusRingMaskBounds: NSRect { bounds }

        override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let fill = Self.brightnessAdjusted(Self.resolvedFillColor(), pressed: pressed)
                fill.setFill()
                NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
                let attributes = Self.titleAttributes(enabled: isEnabled, pressed: pressed)
                let textSize = (title as NSString).size(withAttributes: attributes)
                let textRect = bounds.insetBy(dx: 0, dy: max(0, (bounds.height - ceil(textSize.height)) / 2))
                (title as NSString).draw(in: textRect, withAttributes: attributes)
            }
        }

        override func becomeFirstResponder() -> Bool {
            let accepted = super.becomeFirstResponder()
            if accepted {
                needsDisplay = true
                noteFocusRingMaskChanged()
                reportFocus(gained: true)
            }
            return accepted
        }

        override func resignFirstResponder() -> Bool {
            let accepted = super.resignFirstResponder()
            if accepted {
                needsDisplay = true
                noteFocusRingMaskChanged()
                reportFocus(gained: false)
            }
            return accepted
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            return sendAction(action, to: target)
        }

        func setPressed(_ flag: Bool) {
            guard pressed != flag else { return }
            pressed = flag
            needsDisplay = true
            pressedObserver?(flag)
        }

        func dismantle() {
            focus.cancel()
            performAction = {}
            focusObservationGeneration = nil
            observeFocusGain = { _, _ in }
            observeFocusLoss = { _, _ in }
            pressedObserver = nil
        }

        @objc func invoke() { performAction() }

        /// The observation is deferred to the next main-actor turn and re-checked against the
        /// responder state, exactly like the retired native candidate's proven report path;
        /// the reading state then checks the captured generation and token against its
        /// current appearance and request.
        private func reportFocus(gained: Bool) {
            let token = focus.currentToken
            let generation = focusObservationGeneration
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard (window?.firstResponder === self) == gained else { return }
                if gained {
                    observeFocusGain(generation, token)
                } else {
                    observeFocusLoss(generation, token)
                }
            }
        }

        /// Font size comes from the shared type scale; every colour from the shared palette.
        private static var titleFont: NSFont {
            NSFont.systemFont(ofSize: HfTextStyle.body.pointSize, weight: .semibold)
        }

        private static func resolvedFillColor() -> NSColor { NSColor(Color.runningBG) }

        private static func resolvedTitleColor() -> NSColor { NSColor(Color.accentLink) }

        private static func titleAttributes(enabled: Bool, pressed: Bool) -> [NSAttributedString.Key: Any] {
            [.font: titleFont,
             .foregroundColor: brightnessAdjusted(resolvedTitleColor(), pressed: pressed).withAlphaComponent(enabled ? 1 : 0.5),
             .paragraphStyle: centeredParagraph]
        }

        private static var centeredParagraph: NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byClipping
            return style
        }

        /// The pressed state reproduces the tinted style's `.brightness(-0.04)` feedback:
        /// 0.04 subtracted per channel (clamped) from both the fill and the title ink.
        private static func brightnessAdjusted(_ color: NSColor, pressed: Bool) -> NSColor {
            guard pressed, let rgb = color.usingColorSpace(.sRGB) else { return color }
            return NSColor(red: max(0, rgb.redComponent - 0.04),
                           green: max(0, rgb.greenComponent - 0.04),
                           blue: max(0, rgb.blueComponent - 0.04),
                           alpha: rgb.alphaComponent)
        }
    }
}

// MARK: - ResourceSlotsOwnerFocus

/// A pending restoration is retried across every realized owner control, mirroring
/// `CallerApprovalNativeFocus.retry(in:)`; readiness and owner geometry paths funnel here.
@MainActor
enum ResourceSlotsOwnerFocus {
    static func retry(in view: NSView) {
        if let control = view as? ResourceSlotsOwnerButton.Control { control.retryFocusRestoration() }
        for child in view.subviews { retry(in: child) }
    }
}

extension ResourceSlotsOwnerButton.Control {
    func retryFocusRestoration() { focus.retry() }

    /// Test-side evidence: the control currently holds an unconsumed focus-return token.
    var hasPendingFocusRequest: Bool { focus.hasPendingRequest }
}

#if DEBUG
private struct ResourceSlotsOwnerButtonPreview: View {
    private func previewButton(title: String, label: String, identifier: String) -> ResourceSlotsOwnerButton {
        ResourceSlotsOwnerButton(title: title, label: label, identifier: identifier, token: nil,
                                 isReady: { false }, authorizedResponder: { nil }, acknowledge: { _ in },
                                 observeFocusGain: { _, _ in }, observeFocusLoss: { _, _ in }, userMovedFocus: {},
                                 action: {})
    }

    var body: some View {
        VStack(spacing: HfRadius.Metrics.spacing12) {
            HStack(spacing: HfRadius.Metrics.spacing12) {
                previewButton(title: "Open task", label: "Open task Build turn, task-1",
                              identifier: "resource-slots-owner-preview")
                previewButton(title: "Open workflow run", label: "Open workflow run A deployment run, run-1 / attempt-2",
                              identifier: "resource-slots-owner-preview-2")
            }
            HStack(spacing: HfRadius.Metrics.spacing12) {
                previewButton(title: "Open task", label: "Open task Build turn, task-1",
                              identifier: "resource-slots-owner-preview-disabled").disabled(true)
            }
        }
        .padding()
        .background(Color.windowBG)
    }
}

#Preview("Resource slots owner button - light") { ResourceSlotsOwnerButtonPreview().preferredColorScheme(.light) }
#Preview("Resource slots owner button - dark") { ResourceSlotsOwnerButtonPreview().preferredColorScheme(.dark) }
#endif
