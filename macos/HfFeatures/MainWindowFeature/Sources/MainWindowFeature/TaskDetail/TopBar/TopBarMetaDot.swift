//
//  TopBarMetaDot.swift
//  MainWindowFeature
//
//  The marker a group's top bar draws where its enforcement sentence did not fit (HarflowDesign 4ff7d83
//  `lanes-titled-minimum`): a 6 pt dot in a 16 x 16 target that takes keyboard focus, speaks the sentence once, and
//  shows it in a popover on hover or focus. Escape dismisses the popover until both hover and focus have left. The
//  popover never takes key focus, so the dot stays the first responder.
//

import AppKit
import SwiftUI

// MARK: - TopBarMetaDotState

/// When the popover shows: while hovered or focused, unless Escape dismissed it since both last left.
struct TopBarMetaDotState: Equatable {
    private(set) var isHovering = false
    private(set) var isFocused = false
    /// A press through accessibility: shows the popover without hover, until focus leaves or it is dismissed.
    private(set) var isPressed = false
    private(set) var isDismissed = false

    var showsPopover: Bool { (isHovering || isFocused || isPressed) && !isDismissed }

    mutating func setHovering(_ value: Bool) { isHovering = value; settle() }
    mutating func setFocused(_ value: Bool) {
        isFocused = value
        if !value { isPressed = false }
        settle()
    }

    /// An accessibility press: a transient show (it never sets hover, which only the pointer clears).
    mutating func press() { isPressed = true; isDismissed = false }

    /// Escape: hides the popover until hover, focus and press have all left.
    mutating func dismiss() { isDismissed = true; isPressed = false; settle() }

    /// The dot was hidden or left its window: nothing is hovered, focused or pressed any more.
    mutating func reset() { self = TopBarMetaDotState() }

    private mutating func settle() { if !isHovering, !isFocused, !isPressed { isDismissed = false } }
}

// MARK: - TopBarMetaDotView

/// The 16 x 16 focus target and its dot.
final class TopBarMetaDotView: NSView {
    static let side: CGFloat = 16
    static let dotDiameter: CGFloat = 6

    var sentence = "" {
        didSet { if oldValue != sentence { setAccessibilityLabel(sentence); refreshPopover() } }
    }

    private(set) var state = TopBarMetaDotState()
    private var popover: NSPopover?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: Self.side, height: Self.side) }
    override var acceptsFirstResponder: Bool { !isHidden }
    override var canBecomeKeyView: Bool { !isHidden }
    override var focusRingMaskBounds: NSRect { bounds }

    /// A dot the layout gave no width is not there: hidden, so it takes no focus and has no accessibility element.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let collapsed = newSize.width < 1
        if isHidden != collapsed { isHidden = collapsed }
        setAccessibilityElement(!collapsed)
    }

    /// Whether the sentence's popover is currently shown.
    var isPopoverShown: Bool { popover?.isShown == true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill() }

    override func draw(_ dirtyRect: NSRect) {
        let rect = NSRect(x: (bounds.width - Self.dotDiameter) / 2, y: (bounds.height - Self.dotDiameter) / 2,
                          width: Self.dotDiameter, height: Self.dotDiameter)
        NSColor(TaskScreenStyle.Colors.textTertiary.color).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }

    // MARK: Hover, focus, Escape

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { state.setHovering(true); refreshPopover() }
    override func mouseExited(with event: NSEvent) { state.setHovering(false); refreshPopover() }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { state.setFocused(true); needsDisplay = true; refreshPopover() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { state.setFocused(false); needsDisplay = true; refreshPopover() }
        return accepted
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, isPopoverShown {
            state.dismiss()
            refreshPopover()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard isPopoverShown else { return }
        state.dismiss()
        refreshPopover()
    }

    override func accessibilityPerformPress() -> Bool {
        // Focus is what ends the press: taking it here means moving focus away closes the popover.
        // A refused focus leaves nothing pressed, since focus loss is what would end the press.
        guard window?.makeFirstResponder(self) == true else { return false }
        state.press()
        refreshPopover()
        return true
    }

    override func viewDidHide() { super.viewDidHide(); state.reset(); closePopover() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { state.reset(); closePopover() }
    }

    override func layout() {
        super.layout()
        // The toolbar can move the dot after the popover opened: keep it anchored to the dot.
        if let popover, popover.isShown { popover.positioningRect = bounds }
    }

    // MARK: Popover

    private func refreshPopover() {
        guard window != nil, !isHidden, !sentence.isEmpty, state.showsPopover else { closePopover(); return }
        if let popover, popover.isShown { return }
        let content = Text(sentence)
            .font(.hf(.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .fixedSize()
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: content)
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    private func closePopover() {
        popover?.close()
        popover = nil
    }
}

// MARK: - TopBarMetaDot

/// The dot in a group's top bar. The principal's layout gives it a zero width unless the sentence was dropped; a
/// zero-width dot hides itself, takes no focus and is not in the accessibility tree.
struct TopBarMetaDot: NSViewRepresentable {
    let sentence: String

    func makeNSView(context _: Context) -> TopBarMetaDotView {
        let view = TopBarMetaDotView(frame: NSRect(x: 0, y: 0, width: TopBarMetaDotView.side, height: TopBarMetaDotView.side))
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    func updateNSView(_ view: TopBarMetaDotView, context _: Context) {
        view.sentence = sentence
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: TopBarMetaDotView, context _: Context) -> CGSize? {
        if let width = proposal.width, width < 1 { return .zero }
        return CGSize(width: TopBarMetaDotView.side, height: TopBarMetaDotView.side)
    }
}
