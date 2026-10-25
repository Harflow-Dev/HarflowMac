import AppKit
import Combine
import SwiftUI

// MARK: - ApprovalFocusOperation

/// Realized controls consume focus only after the feed's positioning transaction settles.
/// Attachment, layout and activation retry an unconsumed intent without a timeout. Once
/// consumed, subsequent layout and ordinary model refreshes cannot reclaim keyboard focus.
@MainActor
private final class ApprovalFocusOperation {
    private var token: UUID?
    private var consumed: UUID?
    private weak var view: NSView?
    private var isReady: () -> Bool = { false }
    private var acknowledge: (UUID) -> Void = { _ in }
    private var observation: AnyCancellable?
    private var attempt: Task<Void, Never>?
    private var attemptGeneration = UUID()

    func configure(token: UUID?, view: NSView, isReady: @escaping () -> Bool,
                   acknowledge: @escaping (UUID) -> Void) {
        if self.token != token {
            attempt?.cancel()
            attempt = nil
            self.token = token
            observation = nil
        }
        self.view = view
        self.isReady = isReady
        self.acknowledge = acknowledge
        guard let token, token != consumed else { return }
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

    func retry() {
        guard let token, token != consumed, attempt == nil else { return }
        let generation = UUID()
        attemptGeneration = generation
        attempt = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            defer { if attemptGeneration == generation { attempt = nil } }
            guard !Task.isCancelled, self.token == token, consumed != token, isReady(),
                  let view, let window = view.window,
                  window.isKeyWindow, NSApplication.shared.isActive,
                  !view.isHiddenOrHasHiddenAncestor, !view.visibleRect.isEmpty,
                  window.makeFirstResponder(view), window.firstResponder === view else { return }
            await Task.yield()
            guard !Task.isCancelled, self.token == token, consumed != token, isReady(),
                  view.window === window, window.isKeyWindow, window.firstResponder === view else { return }
            consumed = token
            observation = nil
            acknowledge(token)
        }
    }
}

// MARK: - ApprovalDecisionButton

/// The visible native decision control remains the keyboard target inside recycled table hosts.
struct ApprovalDecisionButton: NSViewRepresentable {
    let title: String
    let enabled: Bool
    let identifier: String
    let token: UUID?
    let isFocusReady: () -> Bool
    let action: () -> Void
    let acknowledge: (UUID) -> Void

    func makeNSView(context: Context) -> Control {
        let button = Control(title: title, target: nil, action: nil)
        button.cell = Cell(textCell: title)
        button.setButtonType(.momentaryPushIn)
        button.bezelStyle = .rounded
        button.target = button
        button.action = #selector(Control.invoke)
        return button
    }

    func updateNSView(_ button: Control, context: Context) {
        button.title = title
        button.isEnabled = enabled && context.environment.isEnabled
        button.setAccessibilityIdentifier(identifier)
        button.performDecision = action
        button.focus.configure(token: button.isEnabled ? token : nil, view: button, isReady: isFocusReady,
                               acknowledge: acknowledge)
    }

    /// AppKit exposes the button cell as its accessible element in ordinary hosted windows.
    final class Cell: NSButtonCell {
        override func accessibilityPerformPress() -> Bool {
            guard isEnabled, let button = controlView as? Control else { return false }
            return button.accessibilityPerformPress()
        }
    }

    final class Control: NSButton {
        fileprivate let focus = ApprovalFocusOperation()
        var performDecision: () -> Void = {}

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            focus.retry()
        }

        override func layout() {
            super.layout()
            focus.retry()
        }

        override func accessibilityPerformPress() -> Bool {
            guard isEnabled else { return false }
            return sendAction(action, to: target)
        }

        @objc func invoke() { performDecision() }
    }
}

// MARK: - ApprovalDetailsScroll

/// Preserve the complete selectable SwiftUI fields in a bounded native scroll view whose
/// own responder handles navigation keys. Keyboard scrolling remains inside the action details.
struct ApprovalDetailsScroll<Content: View>: NSViewRepresentable {
    let identifier: String
    let label: String
    let token: UUID?
    let isFocusReady: () -> Bool
    let acknowledge: (UUID) -> Void
    @ViewBuilder let content: () -> Content

    func makeNSView(context: Context) -> ApprovalDetailsScrollView { ApprovalDetailsScrollView() }

    func updateNSView(_ scroll: ApprovalDetailsScrollView, context: Context) {
        scroll.content = AnyView(content().modifier(ActivityFeedNativeInheritedEnvironment(environment: context.environment)))
        scroll.setAccessibilityIdentifier(identifier)
        scroll.setAccessibilityLabel(label)
        scroll.focus.configure(token: token, view: scroll, isReady: isFocusReady, acknowledge: acknowledge)
        scroll.needsLayout = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ApprovalDetailsScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = nsView.measure(width: width)
        return CGSize(width: width, height: min(220, height))
    }
}

// MARK: - ApprovalDetailsScrollView

final class ApprovalDetailsScrollView: NSScrollView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    fileprivate let focus = ApprovalFocusOperation()
    var content = AnyView(EmptyView()) {
        didSet { contentNeedsUpdate = true }
    }

    private var contentNeedsUpdate = true
    private var contentWidth: CGFloat?

    init() {
        super.init(frame: .zero)
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        focusRingType = .exterior
        host.sizingOptions = [.intrinsicContentSize]
        documentView = host
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }

    // NSScrollView normally forwards focus to its document. This scroll view owns navigation
    // keys itself, keeping read-only action scrolling out of the activity feed's responder chain.
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        noteFocusRingMaskChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        noteFocusRingMaskChanged()
        return true
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    func measure(width: CGFloat) -> CGFloat {
        if contentNeedsUpdate || contentWidth != width {
            contentNeedsUpdate = false
            contentWidth = width
            host.rootView = AnyView(content.frame(width: width, alignment: .leading))
        }
        host.frame.size.width = width
        return max(0, host.fittingSize.height)
    }

    override func layout() {
        super.layout()
        let width = contentSize.width
        if width > 0 { host.frame.size = CGSize(width: width, height: measure(width: width)) }
        focus.retry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focus.retry()
    }

    override func keyDown(with event: NSEvent) {
        let current = contentView.bounds.origin.y
        let page = max(1, contentView.bounds.height - verticalPageScroll)
        let next: CGFloat
        switch event.specialKey {
        case .pageDown: next = current + page
        case .pageUp: next = current - page
        case .downArrow: next = current + verticalLineScroll
        case .upArrow: next = current - verticalLineScroll
        case .home: next = 0
        case .end: next = host.bounds.height
        default:
            super.keyDown(with: event)
            return
        }
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x,
                                      y: min(max(0, next), max(0, host.bounds.height - contentView.bounds.height))))
        reflectScrolledClipView(contentView)
    }
}

// MARK: - CallerApprovalNativeFocus

@MainActor
enum CallerApprovalNativeFocus {
    /// A scroll-intent acknowledgement may change readiness without changing the card entry.
    /// Retry after the owning reconcile transaction even when no host layout is necessary.
    static func retry(in view: NSView) {
        if let button = view as? ApprovalDecisionButton.Control { button.focus.retry() }
        if let scroll = view as? ApprovalDetailsScrollView { scroll.focus.retry() }
        for child in view.subviews { retry(in: child) }
    }
}
