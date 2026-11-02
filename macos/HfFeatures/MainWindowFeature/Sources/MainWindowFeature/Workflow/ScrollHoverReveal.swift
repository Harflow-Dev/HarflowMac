import AppKit
import HfUI
import SwiftUI

// MARK: - ScrollRevealSchedule

/// Decides whether a hovered scroll view's scroller should currently be revealed: while the pointer
/// is over it, and for a linger period after the pointer leaves. Pure value type with an injectable
/// monotonic clock, so the timing contract is testable without AppKit.
struct ScrollRevealSchedule {
    private(set) var isHovering = false
    private(set) var lingerDeadline: TimeInterval?
    private let lingerDuration: TimeInterval
    private let clock: () -> TimeInterval

    init(
        lingerDuration: TimeInterval = ScrollHoverRevealOwner.lingerDuration,
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.lingerDuration = lingerDuration
        self.clock = clock
    }

    /// The pointer entered: hover is on and any pending linger deadline is cleared.
    mutating func enter() {
        isHovering = true
        lingerDeadline = nil
    }

    /// The pointer left: hover is off and the reveal lingers until the deadline.
    mutating func exit() {
        guard isHovering else { return }
        isHovering = false
        lingerDeadline = clock() + lingerDuration
    }

    /// Re-validates a hover that may have gone stale (missed exit event): the pointer must still be
    /// inside the scroll view and its window key, otherwise the hover ends like a normal exit.
    mutating func refresh(pointerInside: Bool, windowIsKey: Bool) {
        guard isHovering, !(pointerInside && windowIsKey) else { return }
        exit()
    }

    /// Clears hover and linger state, keeping the injected clock and linger duration.
    mutating func resetHover() {
        isHovering = false
        lingerDeadline = nil
    }

    /// True while hovering, or before the linger deadline has passed.
    func shouldReveal() -> Bool {
        if isHovering { return true }
        guard let lingerDeadline else { return false }
        return clock() < lingerDeadline
    }
}

// MARK: - ScrollHoverRevealOwner

/// Keeps a scroll view's overlay scroller revealed while the pointer is over the scroll view, and
/// for `lingerDuration` after it leaves, by flashing the scrollers on a timer. It owns one tracking
/// area on the scroll view. Enter and exit are geometric for the visible rect, so the pointer moving
/// onto the scroller subview is not an exit. `NSTrackingArea.owner` is weak, so the representable's
/// coordinator must retain this owner for as long as it is attached.
@MainActor
final class ScrollHoverRevealOwner: NSResponder {
    /// Time between scroller flashes while revealed; below AppKit's overlay visible period.
    nonisolated static let refreshInterval: TimeInterval = 0.5
    /// How long the scroller stays revealed after the pointer leaves the scroll view.
    nonisolated static let lingerDuration: TimeInterval = 1.5

    private(set) weak var scrollView: NSScrollView?
    private(set) weak var window: NSWindow?
    private(set) var trackingArea: NSTrackingArea?
    private(set) var refreshTimer: Timer?
    private var schedule: ScrollRevealSchedule
    private let flash: (NSScrollView) -> Void
    private let pointerState: @MainActor (NSScrollView) -> PointerState
    private var hasFlashed = false
    private var resignObserver: NSObjectProtocol?

    /// The pointer position (in scroll view coordinates) and key-window state read on each tick.
    struct PointerState {
        var location: NSPoint?
        var windowIsKey: Bool
    }

    /// True while the refresh timer is scheduled.
    var isTimerActive: Bool { refreshTimer?.isValid ?? false }

    init(
        flash: @escaping (NSScrollView) -> Void = { $0.flashScrollers() },
        schedule: ScrollRevealSchedule = ScrollRevealSchedule(),
        pointerState: @escaping @MainActor (NSScrollView) -> PointerState = ScrollHoverRevealOwner.livePointerState
    ) {
        self.pointerState = pointerState
        self.flash = flash
        self.schedule = schedule
        super.init()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Installs the tracking area on `scrollView`. Idempotent for the same scroll view; moving to a
    /// different one removes the old area first.
    func attach(to scrollView: NSScrollView) {
        if self.scrollView === scrollView, trackingArea != nil, window === scrollView.window { return }
        detach()
        self.scrollView = scrollView
        // `.activeInKeyWindow`: the reveal is a focused-window affordance, and a resigned window
        // is also treated as an exit. `.inVisibleRect` keeps the area matched to the scroll view.
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        scrollView.addTrackingArea(area)
        trackingArea = area
        window = scrollView.window
        if let window {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerExited() }
            }
        }
    }

    /// Removes the tracking area, the notification observer and the timer. Safe to repeat.
    func detach() {
        stopTimer()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        if let trackingArea { scrollView?.removeTrackingArea(trackingArea) }
        trackingArea = nil
        scrollView = nil
        window = nil
        schedule.resetHover()
    }

    override func mouseEntered(with _: NSEvent) { pointerEntered() }

    override func mouseExited(with _: NSEvent) { pointerExited() }

    /// Marks the pointer as inside; flashes immediately and starts refreshing unless already running.
    func pointerEntered() {
        guard let scrollView else { return }
        schedule.enter()
        // Re-entry (including during linger) starts a new reveal: the next flash must not be skipped.
        hasFlashed = false
        guard !isTimerActive else { return }
        flash(scrollView)
        hasFlashed = true
        startTimer()
    }

    /// Marks the pointer as outside; the reveal lingers until the schedule's deadline.
    func pointerExited() {
        schedule.exit()
    }

    /// One refresh step; public to the module so detach behaviour is testable.
    func tick() {
        guard let scrollView, trackingArea != nil else {
            stopTimer()
            return
        }
        let state = pointerState(scrollView)
        if schedule.isHovering {
            schedule.refresh(
                pointerInside: state.location.map { scrollView.visibleRect.contains($0) } ?? false,
                windowIsKey: state.windowIsKey
            )
        }
        guard schedule.shouldReveal() else {
            stopTimer()
            return
        }
        // AppKit keeps the scroller revealed while the pointer is over it; re-flashing could pulse.
        if schedule.isHovering, hasFlashed, let location = state.location,
           scrollView.horizontalScroller?.frame.contains(location) == true {
            return
        }
        flash(scrollView)
        hasFlashed = true
    }

    /// Reads the real pointer position, in scroll view coordinates, and the window's key state.
    static func livePointerState(_ scrollView: NSScrollView) -> PointerState {
        guard let window = scrollView.window else { return PointerState(location: nil, windowIsKey: false) }
        return PointerState(
            location: scrollView.convert(window.mouseLocationOutsideOfEventStream, from: nil),
            windowIsKey: window.isKeyWindow
        )
    }

    // Scheduled in the default run-loop mode on purpose: it pauses during a knob drag (event
    // tracking), when AppKit already keeps the scroller revealed. Do not switch to `.common`.
    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        hasFlashed = false
    }
}

// MARK: - ScrollHoverReveal

/// Noninteractive probe placed in a scroll view's content (`.background(ScrollHoverReveal())`). It
/// resolves its own enclosing `NSScrollView`, so it can never target an outer scroll view, and it
/// reveals that scroll view's scrollers while hovered. The coordinator retains the owner.
struct ScrollHoverReveal: NSViewRepresentable {
    @MainActor
    final class Coordinator {
        var owner: ScrollHoverRevealOwner?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScrollHoverRevealAttachmentView {
        let view = ScrollHoverRevealAttachmentView()
        view.setAccessibilityElement(false)
        view.onHierarchyChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view, let coordinator else { return }
            Self.sync(view: view, coordinator: coordinator)
        }
        Self.sync(view: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: ScrollHoverRevealAttachmentView, context: Context) {
        Self.sync(view: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: ScrollHoverRevealAttachmentView, coordinator: Coordinator) {
        view.onHierarchyChange = nil
        coordinator.owner?.detach()
        coordinator.owner = nil
    }

    /// Attaches to the current enclosing scroll view, re-attaches on reparent, and releases when the
    /// view leaves its window.
    @MainActor
    private static func sync(view: ScrollHoverRevealAttachmentView, coordinator: Coordinator) {
        guard view.window != nil, let scroll = view.enclosingScrollView else {
            coordinator.owner?.detach()
            coordinator.owner = nil
            return
        }
        if let owner = coordinator.owner, owner.scrollView === scroll, owner.window === view.window, owner.trackingArea != nil { return }
        coordinator.owner?.detach()
        let owner = coordinator.owner ?? ScrollHoverRevealOwner()
        owner.attach(to: scroll)
        coordinator.owner = owner
    }
}

// MARK: - ScrollHoverRevealAttachmentView

/// A zero-footprint attachment point that only reports its own mount changes.
final class ScrollHoverRevealAttachmentView: NSView {
    var onHierarchyChange: (() -> Void)?

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onHierarchyChange?()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onHierarchyChange?()
    }
}

#if DEBUG
#Preview("Scroll hover reveal") {
    ScrollView(.horizontal) {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            ForEach(0 ..< 20, id: \.self) { Text("Item \($0)").padding(HfRadius.Metrics.spacing8) }
        }
        .padding(.bottom, WorkflowScrollRowMetrics.gutter)
        .background(ScrollHoverReveal())
    }
    .frame(width: 320)
}
#endif
