import AppKit

@MainActor func activityMountedTestWindow(_ host: NSView, style: NSWindow.StyleMask) -> NSWindow {
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                          styleMask: style, backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    return window
}

@MainActor func activityNativeTestScroll(_ scroll: NSScrollView, to offset: CGFloat) {
    NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
    scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
    scroll.reflectScrolledClipView(scroll.contentView)
    NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
}
