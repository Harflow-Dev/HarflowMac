import AppKit
import Combine
import SwiftUI

// MARK: - FollowLiveScrollState

/// Keeps the pre-update follow decision when content grows, and yields to upward navigation.
struct FollowLiveScrollState {
    private(set) var isFollowing = true
    private var previousOffset: CGFloat?

    mutating func observe(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) {
        let isAtBottom = contentHeight - offset - viewportHeight <= 24
        if isAtBottom {
            isFollowing = true
        } else if let previousOffset, offset < previousOffset - 0.5 {
            isFollowing = false
        }
        previousOffset = offset
    }

    /// Loading older activity must retain its history anchor even if the feed previously fit.
    mutating func suspend() { isFollowing = false }
}

// MARK: - LiveScrollPositionObserver

/// Reads the native scroll position on macOS 14, including wheel, scrollbar and keyboard moves.
/// Mounted in the feed content so it finds that feed's own enclosing scroll view.
struct LiveScrollPositionObserver: NSViewRepresentable {
    let onPosition: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> LiveScrollPositionView {
        let view = LiveScrollPositionView()
        view.onPosition = onPosition
        return view
    }

    func updateNSView(_ nsView: LiveScrollPositionView, context: Context) {
        nsView.onPosition = onPosition
    }
}

// MARK: - LiveScrollPositionView

final class LiveScrollPositionView: NSView {
    var onPosition: ((CGFloat, CGFloat, CGFloat) -> Void)?
    private weak var observedScrollView: NSScrollView?
    private var subscriptions = Set<AnyCancellable>()

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            subscriptions.removeAll()
            observedScrollView = nil
        } else {
            // SwiftUI installs the hosting hierarchy after makeNSView returns.
            DispatchQueue.main.async { [weak self] in self?.attach() }
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard window != nil, let scroll = enclosingScrollView, scroll !== observedScrollView,
              let document = scroll.documentView else { return }
        subscriptions.removeAll()
        observedScrollView = scroll
        scroll.contentView.postsBoundsChangedNotifications = true
        document.postsFrameChangedNotifications = true
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scroll.contentView),
            (NSView.frameDidChangeNotification, document)
        ] {
            NotificationCenter.default
.publisher(for: name, object: object)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.reportPosition() }
                .store(in: &subscriptions)
        }
        reportPosition()
    }

    private func reportPosition() {
        guard let scroll = observedScrollView, let document = scroll.documentView else { return }
        let visible = scroll.documentVisibleRect
        let offset = document.isFlipped ? visible.minY : document.bounds.maxY - visible.maxY
        onPosition?(offset, document.bounds.height, visible.height)
    }
}

// MARK: - FollowLiveScroll

private struct FollowLiveScrollKey: Equatable {
    let token: ActivityUpdateToken
    let enabled: Bool
}

extension View {
    /// Coalesces streaming changes after layout and avoids competing scroll animations.
    func followLiveScroll(token: ActivityUpdateToken, enabled: Bool, proxy: ScrollViewProxy, target: String) -> some View {
        task(id: FollowLiveScrollKey(token: token, enabled: enabled)) {
            await Task.yield()
            guard enabled, !Task.isCancelled else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { proxy.scrollTo(target, anchor: .bottom) }
        }
    }
}
