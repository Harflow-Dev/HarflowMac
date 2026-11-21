import AppKit
import Combine
import HfUI
import QuartzCore
import SwiftUI

// MARK: - TaskComposerNativeEdge

@MainActor
final class TaskComposerNativeEdge {
    private weak var scroll: NSScrollView?
    private weak var observedDocument: NSView?
    private weak var observedWindow: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var documentObservers: [NSObjectProtocol] = []
    private var focusObservation: AnyCancellable?
    private var paintQueued = false
    private var enabled = false
    private var positioned = false
    private var suppressForReveal = false
    private let decoration = TaskComposerEdgeView()

    var actionOverlap: ((CGRect) -> Bool)?

    var usesWindowBackground = false {
        didSet { if usesWindowBackground != oldValue { schedulePaint() } }
    }

    func install(in scroll: NSScrollView) {
        stop()
        self.scroll = scroll
        decoration.onWindowChange = { [weak self] in self?.schedulePaint() }
        scroll.addSubview(decoration, positioned: .above, relativeTo: scroll.contentView)
        let clip = scroll.contentView
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        scroll.postsFrameChangedNotifications = true
        observe(NSView.boundsDidChangeNotification, object: clip)
        observe(NSView.frameDidChangeNotification, object: clip)
        observe(NSView.frameDidChangeNotification, object: scroll)
        schedulePaint()
    }

    func update(enabled: Bool, positioned: Bool, suppressForReveal: Bool = false) {
        self.enabled = enabled
        self.positioned = positioned
        self.suppressForReveal = suppressForReveal
        schedulePaint()
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        documentObservers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        documentObservers.removeAll()
        focusObservation = nil
        actionOverlap = nil
        observedDocument = nil
        observedWindow = nil
        decoration.onWindowChange = nil
        decoration.removeFromSuperview()
        decoration.isHidden = true
        scroll = nil
        paintQueued = false
    }

    private func observe(_ name: Notification.Name, object: NSView) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.schedulePaint() }
        })
    }

    private func refreshDocument(_ document: NSView) {
        guard observedDocument !== document else { return }
        documentObservers.forEach(NotificationCenter.default.removeObserver)
        documentObservers.removeAll()
        observedDocument = document
        document.postsFrameChangedNotifications = true
        document.postsBoundsChangedNotifications = true
        for name in [NSView.frameDidChangeNotification, NSView.boundsDidChangeNotification] {
            documentObservers.append(NotificationCenter.default.addObserver(forName: name, object: document, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePaint() }
            })
        }
    }

    private func refreshWindow(_ window: NSWindow?) {
        guard observedWindow !== window else { return }
        focusObservation = nil
        observedWindow = window
        focusObservation = window?.publisher(for: \.firstResponder, options: [.new]).sink { [weak self] _ in
            DispatchQueue.main.async { self?.schedulePaint() }
        }
    }

    private func schedulePaint() {
        guard scroll != nil, !paintQueued else { return }
        paintQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, paintQueued else { return }
            paintQueued = false
            paint()
        }
    }

    private func paint() {
        guard let scroll, let document = scroll.documentView else {
            decoration.isHidden = true
            return
        }
        refreshDocument(document)
        refreshWindow(scroll.window)
        let clip = scroll.contentView
        let clipFrame = scroll.convert(clip.bounds, from: clip)
        let height = min(16, clipFrame.height)
        let bottom = scroll.isFlipped ? clipFrame.maxY - height : clipFrame.minY
        decoration.frame = NSRect(x: clipFrame.minX, y: bottom, width: clipFrame.width, height: height)
        let visible = scroll.documentVisibleRect
        let remaining = document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
        decoration.usesWindowBackground = usesWindowBackground
        let actionBand = CGRect(x: visible.minX, y: document.isFlipped ? visible.maxY - 16 : visible.minY,
                                width: visible.width, height: 16)
        decoration.isHidden = !enabled || !positioned || suppressForReveal || actionOverlap?(actionBand) == true || height <= 0 || clipFrame.width <= 0 ||
            remaining <= 1 || hasHostedFocus(in: document, scroll: scroll)
    }

    private func hasHostedFocus(in document: NSView, scroll: NSScrollView) -> Bool {
        let responder = scroll.window?.firstResponder
        let view: NSView? = if let editor = responder as? NSTextView, editor.isFieldEditor {
            editor.delegate as? NSView
        } else {
            responder as? NSView
        }
        guard let view, view !== document, view !== scroll, view !== scroll.contentView else { return false }
        return view.isDescendant(of: document)
    }
}

// MARK: - TaskComposerEdgeView

@MainActor
private final class TaskComposerEdgeView: NSView {
    var onWindowChange: (() -> Void)?
    var usesWindowBackground = false {
        didSet { if usesWindowBackground != oldValue { updateColors() } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer {
        let gradient = CAGradientLayer()
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        return gradient
    }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateColors()
        onWindowChange?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        guard let gradient = layer as? CAGradientLayer else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = NSColor(usesWindowBackground ? Color.windowBG : TaskScreenStyle.Colors.pageBackground.color)
                .usingColorSpace(.deviceRGB) ?? .windowBackgroundColor
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            gradient.colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
            CATransaction.commit()
        }
    }
}
