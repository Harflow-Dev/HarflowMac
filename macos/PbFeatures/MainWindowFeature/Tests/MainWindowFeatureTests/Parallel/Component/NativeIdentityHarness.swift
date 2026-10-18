import AppKit
@testable import MainWindowFeature

// MARK: - Fixture

@MainActor final class NativeIdentityHarness {
    let root: NSView
    let window: NSWindow
    let targetA: NSScrollView
    let targetB: NSScrollView

    init(insets: NSEdgeInsets = NSEdgeInsets()) throws {
        self.root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
        self.targetA = Self.scroll(insets: insets, x: 0)
        self.targetB = Self.scroll(insets: insets, x: 260)
        root.addSubview(targetA)
        root.addSubview(targetB)
        self.window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
    }

    func makeObserver() -> ParallelScrollObservationView {
        let view = ParallelScrollObservationView()
        view.axis = .vertical
        root.addSubview(view)
        return view
    }

    func move(_ scroll: NSScrollView, to offset: CGFloat) {
        scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSView.boundsDidChangeNotification, object: scroll.contentView)
    }

    func resize(_ scroll: NSScrollView, height: CGFloat) {
        var frame = scroll.frame
        frame.size.height = height
        scroll.setFrameSize(frame.size)
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: scroll.contentView)
    }

    func close() { window.contentView = nil; window.close() }

    private static func scroll(insets: NSEdgeInsets, x: CGFloat) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: x, y: 0, width: 220, height: 160))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.contentInsets = insets
        scroll.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 1000))
        return scroll
    }
}
