//
//  ScrollChrome.swift
//  PbUI
//
//  Shared native overlay scroll chrome (the monitor-wide scrollbar amendment, adjudicated plan
//  step 1). One MainActor owner per NSScrollView lives in a weak-key AND weak-value registry,
//  captures the original chrome once before any write, counts independently identified
//  attachment tokens, reasserts overlay after a system preference change, and restores on the
//  last detach. `ScrollChrome` is the precise document probe: placed inside a scroll view's
//  document, it can only ever target that scroll view's own enclosing `NSScrollView` — never an
//  outer lane, canvas or inspector. Public AppKit API only: no custom scrollbar, no width or
//  colour invention, no permanently hidden indicators.
//
//  The user amendment authorizes overlay presentation within the Monitor even when the OS
//  preference is legacy: the preference-change subscription reasserts overlay after AppKit's
//  own native handling. `autohidesScrollers` is written for parity with the legacy fallback,
//  never as proof of idle hiding — overlay scrollers fade at rest natively regardless.
//
//  Chrome fields this touches — and nothing else: `scrollerStyle`, `autohidesScrollers`, and the
//  `controlSize` of each ENABLED axis's scroller. Both axes keep their existing enablement: a
//  disabled axis is never enabled and never gets a manufactured indicator. Scroller objects, the
//  document and content views, scroll enablement, observers, offsets/restoration, identity,
//  follow-live, leases, focus and IME are all owned elsewhere and unchanged.
//
//  Lifecycle rules (ported from the activity feed's proven Phase 4 implementation, which stays
//  in place until its ordinary tests migrate here): each attachment strongly retains its owner
//  while active; the registry and the notification closure hold both the owner and the scroll
//  view weakly; ONE presentation-only `NSScroller.preferredScrollerStyleDidChangeNotification`
//  subscription per owned scroll view is removed on the last detach; and ONE observation of the
//  owned scroll view's own public `scrollerStyle` (native KVO) is subscribed while tokens exist,
//  before the first apply, and invalidated before the final restoration. Restores are skipped
//  when the scroll view has no window, while ownership and both subscriptions are still
//  released — teardown reflow must not mutate a retained view before its sibling observer
//  detaches.
//
//  Native restyle reassertion: NSScrollView.h documents that a scroll view is restyled
//  automatically, and SwiftUI's own update/layout pass can write an owned scroll view back to
//  legacy long after any synchronous reconciliation. The style observation is mutation-driven:
//  its callback never writes chrome synchronously — on any thread it only reads the current
//  native getter on the main actor (the typed ObjC-enum old/new change values bridge as nil, so
//  the current getter is the evidence), ignores an already-overlay value (the owner's own
//  overlay writes included) and coalesces each external non-overlay change into exactly one
//  guarded deferred main-queue reassert, which rechecks original identity and active tokens and
//  clears its pending state before the apply. An unexpected non-main-thread callback never
//  touches the NSView off-actor; it only queues the same guarded main-actor check. An
//  invalidation generation bumped at the final detach drops a delivery already on the main
//  queue even if the owner and the scroll view both stay alive. No timers, no polling, no
//  window scans, no private API, no custom scrollers.
//

import AppKit
import Combine
import SwiftUI

// MARK: - ScrollChromeToken

/// Identifies one attachment. It strongly retains its owner while the attached representable
/// view holds it, so the owner outlives exactly its active attachments and nothing else.
struct ScrollChromeToken: Equatable {
    let owner: ScrollChromeOwner
    let id: Int

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.owner === rhs.owner && lhs.id == rhs.id
    }
}

// MARK: - ScrollChromeOwner

/// The single MainActor owner of one scroll view's overlay chrome: it records the original
/// chrome once, applies the overlay/small presentation to each enabled axis while attached,
/// reasserts overlay after a system preference change, reasserts overlay after AppKit or
/// SwiftUI restyles its own scroll view back to legacy — through one observation of that exact
/// scroll view's public `scrollerStyle`, whose callback only reads and queues and whose write
/// happens in one coalesced guarded deferred main-queue delivery — and restores on the last
/// detach, invalidating that observation before the restoration.
@MainActor
final class ScrollChromeOwner {
    /// The chrome captured at first attach, before any write — both axes' scroller sizes.
    struct OriginalChrome: Equatable {
        let scrollerStyle: NSScroller.Style
        let autohidesScrollers: Bool
        let verticalControlSize: NSControl.ControlSize
        let horizontalControlSize: NSControl.ControlSize
    }

    private(set) weak var scrollView: NSScrollView?
    private var original: OriginalChrome?
    private var activeTokenIDs = Set<Int>()
    private var nextTokenID = 0
    /// A system preference notification arrived while this owner held the scroll view — the
    /// final restore then writes the CURRENT preferred style, never the stale captured one.
    private var preferenceChanged = false
    private var notificationCancellable: AnyCancellable?
    /// ONE observation of this owner's exact scroll view's public `scrollerStyle`, subscribed
    /// before the first apply and invalidated before the final restoration.
    private var styleObservation: NSKeyValueObservation?
    /// True while one deferred style reassert is queued and not yet delivered, so a burst of
    /// external style changes coalesces into a single main-queue reassert.
    private var hasPendingStyleReassert = false
    /// Invalidation generation for queued reasserts, bumped at the final detach so a delivery
    /// already on the main queue is dropped even if this owner and its scroll view stay alive.
    private var styleGeneration = 0

    /// Applies the overlay chrome to `scrollView`, creating the owner if none owns it yet.
    static func attach(to scrollView: NSScrollView) -> ScrollChromeToken {
        let owner = ScrollChromeRegistry.registry.object(forKey: scrollView)
            ?? {
                let owner = ScrollChromeOwner(scrollView: scrollView)
                ScrollChromeRegistry.registry.setObject(owner, forKey: scrollView)
                return owner
            }()
        return owner.attach()
    }

    /// Releases one attachment; the last one restores the scroll view and removes the registry
    /// entry and the notification subscription.
    static func detach(_ token: ScrollChromeToken) {
        token.owner.detach(tokenID: token.id)
    }

    private init(scrollView: NSScrollView) {
        self.scrollView = scrollView
    }

    private func attach() -> ScrollChromeToken {
        if original == nil, let scrollView {
            // The FIRST owner captures the original chrome before writing anything; an
            // overlapping attach finds this owner in the registry and never captures the
            // overlay as original.
            original = OriginalChrome(
                scrollerStyle: scrollView.scrollerStyle,
                autohidesScrollers: scrollView.autohidesScrollers,
                verticalControlSize: scrollView.verticalScroller?.controlSize ?? .regular,
                horizontalControlSize: scrollView.horizontalScroller?.controlSize ?? .regular
            )
        }
        nextTokenID += 1
        let token = ScrollChromeToken(owner: self, id: nextTokenID)
        activeTokenIDs.insert(token.id)
        // The style observation is in place BEFORE the first apply: the apply itself writes
        // scrollerStyle, and a later native restyle is answered from the first write on.
        subscribeToStyleIfNeeded()
        applyChrome()
        subscribeIfNeeded()
        return token
    }

    private func detach(tokenID: Int) {
        guard activeTokenIDs.remove(tokenID) != nil else { return }
        guard activeTokenIDs.isEmpty else { return }
        // Release ownership first: another owner (or a reparenting attach) never sees this owner
        // as the current chrome's captor once its last attachment is gone.
        notificationCancellable?.cancel()
        notificationCancellable = nil
        // Invalidate the style observation BEFORE the original chrome restoration — the restore
        // writes scrollerStyle itself — and drop any reassert already queued: the generation
        // bump makes a late delivery's guard fail even if this owner and the scroll view both
        // stay alive. This teardown holds even when the weak scroll view is already gone.
        styleObservation?.invalidate()
        styleObservation = nil
        styleGeneration += 1
        hasPendingStyleReassert = false
        if let scrollView, let original {
            if scrollView.window != nil {
                restoreChrome(on: scrollView, original: original)
            } else {
                // No visible consumer: skip the restore WRITES, release everything. A later
                // re-attach captures the then-current chrome as its original — best-effort by
                // design, never a promise the historical legacy chrome returns.
            }
        }
        if let scrollView { ScrollChromeRegistry.registry.removeObject(forKey: scrollView) }
        scrollView = nil
        original = nil
        preferenceChanged = false
    }

    /// The overlay chrome itself. Guarded assignments: an already-overlay attachment, an
    /// equality-identical update, or a disabled axis all write nothing.
    func applyChrome() {
        guard !activeTokenIDs.isEmpty, let scrollView else { return }
        if scrollView.scrollerStyle != .overlay { scrollView.scrollerStyle = .overlay }
        if !scrollView.autohidesScrollers { scrollView.autohidesScrollers = true }
        // Size only the axes the scroll view itself enables — never manufacture an indicator.
        if scrollView.hasVerticalScroller, scrollView.verticalScroller?.controlSize != .small {
            scrollView.verticalScroller?.controlSize = .small
        }
        if scrollView.hasHorizontalScroller, scrollView.horizontalScroller?.controlSize != .small {
            scrollView.horizontalScroller?.controlSize = .small
        }
    }

    private func restoreChrome(on scrollView: NSScrollView, original: OriginalChrome) {
        // After a preference change, AppKit has already restyled the scroll view to the user's
        // new preferred style — restore THAT, not the stale captured one.
        let style = preferenceChanged ? NSScroller.preferredScrollerStyle : original.scrollerStyle
        if scrollView.scrollerStyle == .overlay, scrollView.scrollerStyle != style { scrollView.scrollerStyle = style }
        if scrollView.autohidesScrollers, scrollView.autohidesScrollers != original.autohidesScrollers {
            scrollView.autohidesScrollers = original.autohidesScrollers
        }
        if scrollView.verticalScroller?.controlSize == .small,
           scrollView.verticalScroller?.controlSize != original.verticalControlSize {
            scrollView.verticalScroller?.controlSize = original.verticalControlSize
        }
        if scrollView.horizontalScroller?.controlSize == .small,
           scrollView.horizontalScroller?.controlSize != original.horizontalControlSize {
            scrollView.horizontalScroller?.controlSize = original.horizontalControlSize
        }
    }

    /// ONE subscription per owned scroll view, removed on the last detach or deallocation; its
    /// closure holds this owner weakly and reasserts only while an attachment still exists.
    private func subscribeIfNeeded() {
        guard notificationCancellable == nil else { return }
        notificationCancellable = NotificationCenter.default
            .publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, !activeTokenIDs.isEmpty else { return }
                // AppKit has already applied the new preferred style natively (NSScrollView.h);
                // this owner's scroll views asked for overlay, so reassert it — scheduled on
                // the main actor, weakly owned, and only while this owner still holds
                // attachments.
                preferenceChanged = true
                applyChrome()
            }
    }

    /// ONE observation of this owner's exact scroll view's public `scrollerStyle` (native KVO),
    /// subscribed while tokens exist, before the first apply, and invalidated before the final
    /// restore. NSScrollView.h documents that a scroll view is restyled automatically —
    /// SwiftUI's own update/layout pass can write the owned scroll view back to legacy long
    /// after any synchronous reconciliation, and no marker event follows that write. The
    /// callback is mutation-driven only: it never writes chrome synchronously on any thread. It
    /// reads the current native getter on the main actor (typed ObjC-enum old/new change values
    /// bridge as nil, so the current getter is the evidence), ignores an already-overlay value
    /// (this owner's own overlay writes included) and coalesces each external non-overlay
    /// change into exactly one guarded deferred main-queue reassert. An unexpected non-main
    /// thread callback never reads or mutates the NSView off-actor; it only queues the same
    /// guarded main-actor check.
    private func subscribeToStyleIfNeeded() {
        guard styleObservation == nil, let scrollView else { return }
        let scroll = scrollView
        styleObservation = scroll.observe(\.scrollerStyle) { [weak self, weak scroll] _, _ in
            // KVO delivers on the mutating thread; the NSView is never touched off the main
            // actor. On the main thread the main actor's executor is exact, so entering it is
            // safe; any other thread only queues the same check.
            guard Thread.isMainThread else {
                DispatchQueue.main.async { [weak self, weak scroll] in
                    MainActor.assumeIsolated { self?.queueStyleReassert(for: scroll) }
                }
                return
            }
            MainActor.assumeIsolated { self?.queueStyleReassert(for: scroll) }
        }
    }

    /// Reads and queues — never a synchronous chrome write. The current native getter decides:
    /// an already-overlay notification (including this owner's own overlay writes) adds no
    /// work, and each external non-overlay change coalesces into one deferred guarded reassert
    /// whose delivery rechecks the generation, the pending state, active tokens and original
    /// identity, clears the pending state before the apply, and only then — in that deferred
    /// delivery — writes the chrome.
    @MainActor
    private func queueStyleReassert(for observedScroll: NSScrollView?) {
        guard let observedScroll,
              !activeTokenIDs.isEmpty,
              let scrollView, scrollView === observedScroll,
              scrollView.window != nil,
              scrollView.hasVerticalScroller || scrollView.hasHorizontalScroller,
              scrollView.scrollerStyle != .overlay,
              !hasPendingStyleReassert
        else { return }
        hasPendingStyleReassert = true
        let generation = styleGeneration
        DispatchQueue.main.async { [weak self, weak observedScroll] in
            MainActor.assumeIsolated {
                guard let self, let observedScroll,
                      self.styleGeneration == generation,
                      self.hasPendingStyleReassert,
                      !self.activeTokenIDs.isEmpty,
                      let scrollView = self.scrollView, scrollView === observedScroll
                else { return }
                // Clear the pending state BEFORE the apply: the reassert's own overlay write is
                // an already-overlay callback that adds no work, and only a genuinely new
                // external change can enqueue a fresh pass — the delivery never enqueues itself.
                self.hasPendingStyleReassert = false
                guard scrollView.window != nil,
                      scrollView.hasVerticalScroller || scrollView.hasHorizontalScroller
                else { return }
                self.applyChrome()
            }
        }
    }
}

// MARK: - ScrollChromeRegistry

/// The weak-key AND weak-value owner registry — the one shared registry the whole Monitor's
/// overlay chrome flows through. Entries are removed explicitly on the last detach, never
/// lazily purged. Activity feeds use compatibility aliases for this implementation, not a
/// separate registry.
enum ScrollChromeRegistry {
    @MainActor static let registry = NSMapTable<NSScrollView, ScrollChromeOwner>.weakToWeakObjects()
}

// MARK: - ScrollChrome

/// The shared document probe for ordinary scroll containers: placed inside a scroll view's
/// document (`.background(ScrollChrome())` under the scrolling content), it applies the overlay
/// chrome to exactly that enclosing `NSScrollView`. Attaches while at least one axis is enabled,
/// sizes only the enabled axes, and never enables a disabled axis.
public struct ScrollChrome: NSViewRepresentable {
    /// Holds this representable's attachment token — the strong "each attachment retains its
    /// owner while active" link — and outlives the NSView across SwiftUI updates.
    @MainActor
    public final class Coordinator {
        var token: ScrollChromeToken?
    }

    public init() {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeNSView(context: Context) -> ScrollChromeAttachmentView {
        let view = ScrollChromeAttachmentView()
        view.setAccessibilityElement(false)
        view.onHierarchyChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view, let coordinator else { return }
            Self.sync(view: view, coordinator: coordinator)
        }
        // Prefer synchronous attachment: the chrome lands before a scroll observer
        // asynchronously reports its first viewport, without changing that observer.
        Self.sync(view: view, coordinator: context.coordinator)
        return view
    }

    public func updateNSView(_ view: ScrollChromeAttachmentView, context: Context) {
        Self.sync(view: view, coordinator: context.coordinator)
    }

    public static func dismantleNSView(_ view: ScrollChromeAttachmentView, coordinator: Coordinator) {
        view.onHierarchyChange = nil
        if let token = coordinator.token {
            ScrollChromeOwner.detach(token)
            coordinator.token = nil
        }
    }

    /// The single attach/dismantle decision point, always on the main actor: attach to the
    /// current enclosing scroll view while it has at least one enabled axis, re-assert the guarded
    /// chrome on unchanged identity, detach from a previous one on reparent (restoring it before
    /// attaching to the new one), and release when the view has left its window.
    @MainActor
    private static func sync(view: ScrollChromeAttachmentView, coordinator: Coordinator) {
        guard view.window != nil,
              let scroll = view.enclosingScrollView,
              scroll.hasVerticalScroller || scroll.hasHorizontalScroller
        else {
            // Off-window, outside any scroll view, or with both axes deliberately disabled:
            // teardown. When the scroll view's own window is gone too, the owner skips the
            // restore writes by design.
            if let token = coordinator.token {
                ScrollChromeOwner.detach(token)
                coordinator.token = nil
            }
            return
        }
        if let token = coordinator.token, token.owner.scrollView === scroll {
            token.owner.applyChrome()
            return
        }
        if let token = coordinator.token {
            ScrollChromeOwner.detach(token)
            coordinator.token = nil
        }
        coordinator.token = ScrollChromeOwner.attach(to: scroll)
    }
}

// MARK: - ScrollChromeAttachmentView

/// A zero-footprint, noninteractive attachment point: it never becomes an accessibility element,
/// never accepts first responder, and only reports its own mount changes to the probe's
/// main-actor coordinator — all ownership lives there.
public final class ScrollChromeAttachmentView: NSView {
    /// Set by the representable; called on the main thread for every move to a window or a new
    /// superview, exactly the events that can change the enclosing scroll view.
    var onHierarchyChange: (() -> Void)?

    override public var acceptsFirstResponder: Bool { false }

    override public func hitTest(_: NSPoint) -> NSView? { nil }

    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onHierarchyChange?()
    }

    override public func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onHierarchyChange?()
    }
}

#if DEBUG
/// Overflowing dummy data — the native overlay indicator fades at rest, both axes.
private struct ScrollChromePreview: View {
    var body: some View {
        VStack(spacing: PbRadius.Metrics.spacing16) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: PbRadius.Metrics.spacing12) {
                    ForEach(0 ..< 40, id: \.self) { row in
                        Text("Vertical lane — the native indicator fades at rest. Row \(row).")
                            .font(.pb(.reading))
                            .foregroundStyle(Color.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(PbRadius.Metrics.spacing16)
                .background(ScrollChrome())
            }
            ScrollView(.horizontal) {
                HStack(spacing: PbRadius.Metrics.spacing12) {
                    ForEach(0 ..< 20, id: \.self) { column in
                        Text("Column \(column)")
                            .font(.pb(.secondary))
                            .foregroundStyle(Color.secondaryText)
                            .padding(PbRadius.Metrics.spacing8)
                            .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.neutralFill))
                    }
                }
                .padding(PbRadius.Metrics.spacing16)
                .background(ScrollChrome())
            }
        }
        .frame(
            width: PbRadius.Metrics.foundationWidth / 2,
            height: PbRadius.Metrics.foundationHeight / 2
        )
        .background(Color.windowBG)
    }
}

#Preview("ScrollChrome - light") {
    ScrollChromePreview().preferredColorScheme(.light)
}

#Preview("ScrollChrome - dark") {
    ScrollChromePreview().preferredColorScheme(.dark)
}
#endif
