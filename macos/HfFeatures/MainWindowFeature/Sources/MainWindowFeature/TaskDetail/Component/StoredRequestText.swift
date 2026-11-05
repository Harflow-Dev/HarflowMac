import AppKit
import HfUI
import SwiftUI

// MARK: - StoredRequestFocusIntent

/// One explicit request-read handoff; consumed or cancelled intents cannot replay after remounting.
@MainActor
final class StoredRequestFocusIntent {
    private(set) var isPending = true
    func consume() { isPending = false }
    func cancel() { isPending = false }
}

// MARK: - StoredRequestText

/// Literal, selectable stored request text with native text-view focus ownership.
@MainActor
struct StoredRequestText: NSViewRepresentable {
    let text: String
    var focusIntent: StoredRequestFocusIntent?
    var finishedFocus: (StoredRequestFocusIntent) -> Void = { _ in }

    func makeNSView(context _: Context) -> StoredRequestScrollView { StoredRequestScrollView() }

    func updateNSView(_ view: StoredRequestScrollView, context _: Context) {
        view.update(text: text, intent: focusIntent, finished: finishedFocus)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StoredRequestScrollView, context _: Context) -> CGSize? {
        let proposed = proposal.width ?? nsView.bounds.width
        let width = proposed.isFinite && proposed > 0 ? proposed : max(1, nsView.bounds.width)
        return CGSize(width: width, height: min(180, nsView.readingHeight(width: width)))
    }

    static func dismantleNSView(_ view: StoredRequestScrollView, coordinator _: ()) { view.stopObserving() }
}

// MARK: - StoredRequestScrollView

@MainActor
final class StoredRequestScrollView: NSScrollView {
    let requestTextView = NSTextView(frame: .zero)
    private var intent: StoredRequestFocusIntent?
    private var finished: (StoredRequestFocusIntent) -> Void = { _ in }
    private var observers: [NSObjectProtocol] = []
    private weak var observedWindow: NSWindow?
    private var wasAttached = false

    init() {
        super.init(frame: .zero)
        borderType = .noBorder
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        requestTextView.isEditable = false
        requestTextView.isSelectable = true
        requestTextView.isRichText = false
        requestTextView.importsGraphics = false
        requestTextView.allowsUndo = false
        requestTextView.drawsBackground = false
        requestTextView.font = NSFont.systemFont(ofSize: HfTextStyle.reading.pointSize)
        requestTextView.textColor = .textColor
        requestTextView.textContainerInset = .zero
        requestTextView.isHorizontallyResizable = false
        requestTextView.isVerticallyResizable = true
        requestTextView.autoresizingMask = [.width]
        requestTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        requestTextView.textContainer?.widthTracksTextView = true
        requestTextView.textContainer?.heightTracksTextView = false
        requestTextView.textContainer?.lineFragmentPadding = 0
        documentView = requestTextView
    }

    required init?(coder _: NSCoder) { nil }

    func update(text: String, intent next: StoredRequestFocusIntent?, finished: @escaping (StoredRequestFocusIntent) -> Void) {
        self.finished = finished
        if requestTextView.string != text { requestTextView.string = text; needsLayout = true }
        if intent !== next { cancelIntent(); intent = next }
        attemptFocus()
    }

    func readingHeight(width: CGFloat) -> CGFloat {
        guard let container = requestTextView.textContainer, let manager = requestTextView.layoutManager else { return 24 }
        container.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        return max(24, ceil(manager.usedRect(for: container).height))
    }

    override func layout() {
        super.layout()
        let width = max(1, contentView.bounds.width)
        let height = max(contentView.bounds.height, readingHeight(width: width))
        let size = NSSize(width: width, height: height)
        if requestTextView.frame.size != size { requestTextView.setFrameSize(size) }
        attemptFocus()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let previous = observedWindow, previous !== window { cancelIntent() }
        removeObservers()
        guard let window else {
            if wasAttached { cancelIntent() }
            return
        }
        wasAttached = true
        observedWindow = window
        for (name, object) in [(NSWindow.didBecomeKeyNotification, window as AnyObject),
                               (NSApplication.didBecomeActiveNotification, NSApp as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.attemptFocus() }
            })
        }
        attemptFocus()
    }

    func stopObserving() { removeObservers(); cancelIntent() }

    private func removeObservers() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        observedWindow = nil
    }

    private func cancelIntent() {
        guard let previous = intent else { return }
        intent = nil
        guard previous.isPending else { return }
        previous.cancel()
        acknowledge(previous)
    }

    private func attemptFocus() {
        guard let intent, intent.isPending, let window, window === observedWindow,
              window.isKeyWindow, NSApp.isActive, !isHiddenOrHasHiddenAncestor,
              visibleRect.width > 0, visibleRect.height > 0,
              requestTextView.window === window, !requestTextView.isHiddenOrHasHiddenAncestor,
              requestTextView.bounds.width > 0, requestTextView.bounds.height > 0,
              requestTextView.visibleRect.width > 0, requestTextView.visibleRect.height > 0 else { return }
        guard window.makeFirstResponder(requestTextView), window.firstResponder === requestTextView else { return }
        intent.consume()
        acknowledge(intent)
    }

    private func acknowledge(_ intent: StoredRequestFocusIntent) {
        let callback = finished
        Task { @MainActor in callback(intent) }
    }
}
