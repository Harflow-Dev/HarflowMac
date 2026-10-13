//
//  ScrollChromeScope.swift
//  PbUI
//
//  Bounded component-local scroll chrome targeting (adjudicated plan step 2) for the controls and
//  containers whose own NSScrollView cannot be reached by the document probe: TextEditor,
//  multiline TextField, List and Form. The scope brackets its content with two hidden,
//  noninteractive markers whose endpoints share ONE direct superview after at most one sole-child
//  wrapper is normalized per marker; discovery accepts exactly one
//  candidate NSScrollView between the markers' sibling indices in that superview's public
//  subviews — the scroll view itself, or wrapped in at most one wrapper view — and requires the
//  converted frames of the markers, normalized endpoints and candidate to match. The candidate
//  matches by its full converted frame first; only when that fails does one final fallback
//  apply: exact equality against the candidate's bounds inset by its public contentInsets,
//  converted through the candidate's own public coordinate conversion with top/bottom applied
//  per its isFlipped — the shape a container takes when its own native footer safe-area inset
//  excludes part of the content area. Ambiguity (zero or multiple
//  candidates, a missing or differently hosted peer, mismatched frames, no laid-out bounds) fails
//  closed: no attach, as do insets that are negative, nonfinite, leave nonpositive inset bounds
//  or still mismatch; all-zero insets reproduce the full frame and add no fallback, and no inset
//  height is ever guessed as a constant. No window scan, no arbitrary parent descent, no private class-name guesses,
//  no timers, no KVO, no render publications — reconciliation happens on mount, update, reparent
//  and the markers' own frame-changed notifications, guarded by weak identity checks, and only
//  that. A native chrome restyle that SwiftUI's own update/layout pass applies after the
//  synchronous reconciliation is answered by the shared owner's one public style observation,
//  never by a rescan, retry or deferred pass here.
//
//  Applying the scope to a List or Form brackets the container itself, so ownership is
//  independent of row presence: an empty, populated-then-emptied or virtualized list keeps its
//  chrome with no fabricated placeholder rows and no row probes as the sole owner. A native text
//  control with no dedicated NSScrollView is an evidence-backed no-op, not a missing
//  implementation. The shared field editor is never a target: a candidate whose document view is
//  a field-editor NSTextView is rejected, and its scroll/clip ancestors cannot pass the same
//  check either. A no-op scope adds no invisible gesture layer and no focusable or accessibility
//  element.
//
//  Optional native identity disclosure: `scrollChromeScope(onNativeScrollView:)` additionally
//  hands the SAME bounded discovery result to a caller-supplied handler — the scoped container's
//  own NSScrollView, or nil. The two markers report independently into one relay that aggregates
//  them: an identity survives while either live marker still reports it, nil is delivered only
//  once every live marker reports nothing (a churning marker never unseats its peer's scope), an
//  identical NSScrollView with an unchanged document is never redelivered, and delivery is deferred
//  to the main queue with a generation guard so no identity is published during layout and only
//  the newest knowledge ever
//  publishes. Every reference — markers, scroll views, the delivered identity — is weak, so a
//  deallocated candidate is absent at the next report delivery, fail closed; weak zeroing alone
//  does not schedule delivery. The handler changes no chrome behaviour; the
//  markers keep their chrome tokens exactly as before, and a scope installed without a handler
//  leaves the relay unused.
//

import AppKit
import Combine
import SwiftUI

// MARK: - ScrollChromeScopePairID

/// Identity shared by one scope's two markers, held in the modifier's own `@State` so it stays
/// stable across body re-evaluations; nested scopes never pair across each other.
struct ScrollChromeScopePairID: Equatable {
    let raw = UUID()
}

// MARK: - ScrollChromeScopeNativeIdentityHandler

/// Receives the scoped container's own native scroll identity: the bounded marker-pair
/// discovery's NSScrollView, or nil once every live marker reports nothing. Delivery is always
/// main-actor and never happens during a layout pass.
public typealias ScrollChromeScopeNativeIdentityHandler = @MainActor (NSScrollView?) -> Void

// MARK: - ScrollChromeScopeIdentityRelay

/// Aggregates one scope's two independent marker discoveries into a single native scroll-identity
/// stream for the optional `onNativeScrollView` handler. Both markers report their own bounded
/// candidate (or nil) on every reconcile; the relay never invents a target and never scans — it
/// only aggregates what the strict discovery already produced.
///
/// Delivery rules: an identity is live while ANY live marker still reports it; nil publishes only
/// once every live marker reports nothing, so one marker churning (conditional replacement, sheet
/// re-presentation) never unseats its peer's scope. An identical NSScrollView with an unchanged
/// document is never redelivered; a document replacement is disclosed on the next marker report.
/// Delivery is deferred one main-queue hop with a generation guard: a block publishes
/// only when it carries the newest report generation, so coalesced bursts publish once and no
/// handler runs during layout. Every reference — markers, candidates, the last delivered identity
/// — is weak, so a deallocated candidate is absent at the next report delivery (fail closed)
/// and nothing is ever kept alive by the relay. Weak zeroing alone does not schedule delivery;
/// marker reconciliation and dismantling drive publication.
@MainActor
final class ScrollChromeScopeIdentityRelay {
    /// One marker's latest bounded discovery. Both references are weak: a dead marker is purged
    /// before aggregation and a dead candidate reads as absent, never as a delivered identity.
    private struct MarkerIdentity {
        weak var marker: ScrollChromeScopeMarkerView?
        weak var scrollView: NSScrollView?
    }

    private var identities: [ObjectIdentifier: MarkerIdentity] = [:]
    private var onIdentity: ScrollChromeScopeNativeIdentityHandler?
    private weak var lastDelivered: NSScrollView?
    private weak var lastDeliveredDocument: NSView?
    /// Retains the delivered nil state even after a weak document reference zeroes.
    private var lastDeliveredDocumentWasNil = true
    private var lastDeliveryWasNil = true
    /// Bumped by every marker report; a deferred block publishes only under the newest generation.
    private var generation = 0

    /// Installs the handler once per scope instance; the handler is expected to capture
    /// lifetime-stable state (a caller's own holder), so later body evaluations keep the first.
    func install(handler: @escaping ScrollChromeScopeNativeIdentityHandler) {
        guard onIdentity == nil else { return }
        onIdentity = handler
    }

    /// One marker's bounded discovery result — its bracketed candidate, or nil while that marker
    /// isolates nothing. Called from the marker's single main-actor reconciliation point only.
    func report(_ scrollView: NSScrollView?, from marker: ScrollChromeScopeMarkerView) {
        identities[ObjectIdentifier(marker)] = MarkerIdentity(marker: marker, scrollView: scrollView)
        generation &+= 1
        let scheduled = generation
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.deliver(generation: scheduled) }
        }
    }

    /// The deferred publish point: publishes only under the newest report generation, purges dead
    /// markers, reads the CURRENT aggregated state (so a replacement that arrived after
    /// scheduling is what publishes, never a stale identity), deduplicates an unchanged scroll
    /// view and current document pair, and delivers nil exactly on the all-markers-detached
    /// transition. Document changes are read here when marker reports drive delivery.
    private func deliver(generation scheduled: Int) {
        guard scheduled == generation else { return }
        identities = identities.filter { $0.value.marker != nil }
        let aggregated = identities.values.compactMap(\.scrollView).first
        let document = aggregated?.documentView
        let documentChanged = (document == nil) != lastDeliveredDocumentWasNil || document !== lastDeliveredDocument
        let changed = aggregated.map { $0 !== lastDelivered || documentChanged } ?? !lastDeliveryWasNil
        guard changed else { return }
        lastDelivered = aggregated
        lastDeliveredDocument = document
        lastDeliveredDocumentWasNil = document == nil
        lastDeliveryWasNil = aggregated == nil
        onIdentity?(aggregated)
    }
}

// MARK: - ScrollChromeScopeMarkerView

/// One hidden, noninteractive marker of a scope pair: it never draws, never takes part in hit
/// testing, never accepts first responder and never becomes an accessibility element. It reports
/// its own mount and frame changes to its representable's main-actor coordinator — all ownership
/// lives in the shared chrome infrastructure.
final class ScrollChromeScopeMarkerView: NSView {
    /// The identity shared with this marker's peer, set once at creation.
    let pairID: ScrollChromeScopePairID
    var identityRelay: ScrollChromeScopeIdentityRelay?
    /// Set by the representable; called on the main thread for every move to a window or a new
    /// superview, exactly the events that can change the bounded scope.
    var onReconcile: (() -> Void)?

    init(pairID: ScrollChromeScopePairID) {
        self.pairID = pairID
        super.init(frame: .zero)
        // Hidden: no drawing, no hit testing, no accessibility presence.
        isHidden = true
        // The marker's own frame-change notification is the bounded layout-reconciliation
        // signal — first layout and any later resize re-run the guarded attach decision.
        postsFrameChangedNotifications = true
    }

    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onReconcile?()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        onReconcile?()
    }
}

// MARK: - ScrollChromeScopeDiscovery

/// The strict bounded marker-pair rule. Everything here is fail-closed: a missed precondition
/// means "no scroll view", never a broader search.
enum ScrollChromeScopeDiscovery {
    /// How close the converted marker/peer/candidate frames must be to count as the same content
    /// bounds — layout rounding only, not a sizing heuristic.
    static let frameTolerance = PbRadius.Metrics.hairlineStroke

    /// Finds the one candidate NSScrollView bracketed by `marker` and its peer, or nil when the
    /// bounded scope cannot isolate exactly one candidate. Endpoints normalize at most one
    /// sole-child wrapper; discovery stays within their exact shared parent, never descends past
    /// one candidate wrapper level, and never attaches to the shared
    /// field editor or its scroll/clip ancestors. Frame equality tries the candidate's full
    /// converted frame first and otherwise only its bounds inset by its public contentInsets
    /// (top/bottom applied per its flippedness); invalid or still-mismatched inset geometry
    /// fails closed.
    @MainActor
    static func candidate(around marker: ScrollChromeScopeMarkerView) -> NSScrollView? {
        guard let markerEndpoint = endpoint(for: marker),
              let superview = markerEndpoint.superview else { return nil }
        let subviews = superview.subviews
        let peers = subviews.compactMap { view -> ScrollChromeScopeMarkerView? in
            let candidate = view as? ScrollChromeScopeMarkerView
                ?? (view.subviews.count == 1 ? view.subviews.first as? ScrollChromeScopeMarkerView : nil)
            guard let candidate, candidate !== marker, candidate.pairID == marker.pairID else { return nil }
            return candidate
        }
        guard peers.count == 1, let peer = peers.first,
              let peerEndpoint = endpoint(for: peer),
              peerEndpoint.superview === superview,
              let markerIndex = subviews.firstIndex(of: markerEndpoint),
              let peerIndex = subviews.firstIndex(of: peerEndpoint)
        else { return nil }
        // Between sibling indices only, in that superview's public subviews.
        let lower = Swift.min(markerIndex, peerIndex)
        let upper = Swift.max(markerIndex, peerIndex)
        var candidates: [NSScrollView] = []
        for view in subviews[(lower + 1) ..< upper] {
            if let scroll = view as? NSScrollView {
                candidates.append(scroll)
                continue
            }
            // At most one wrapper level: a non-scroll view whose direct subviews contain exactly
            // one NSScrollView. Nothing deeper is ever considered.
            let wrapped = view.subviews.compactMap { $0 as? NSScrollView }
            guard wrapped.count <= 1 else { return nil }
            if wrapped.count == 1 { candidates.append(wrapped[0]) }
        }
        guard candidates.count == 1, let candidate = candidates.first else { return nil }
        // The shared field editor is never a target, nor are its scroll/clip ancestors.
        if let editor = candidate.documentView as? NSTextView, editor.isFieldEditor { return nil }
        // Converted control/marker frames must agree — the candidate is the scoped content
        // itself, not a neighbouring or outer container.
        guard framesMatch(
            marker: marker, markerEndpoint: markerEndpoint,
            peer: peer, peerEndpoint: peerEndpoint, candidate: candidate
        ) else { return nil }
        return candidate
    }

    @MainActor
    private static func endpoint(for marker: ScrollChromeScopeMarkerView) -> NSView? {
        guard let parent = marker.superview else { return nil }
        let directPeers = parent.subviews
.compactMap { $0 as? ScrollChromeScopeMarkerView }
            .filter { $0 !== marker && $0.pairID == marker.pairID }
        if !directPeers.isEmpty { return marker }
        guard parent.subviews.count == 1, parent.subviews.first === marker else { return nil }
        return parent
    }

    @MainActor
    private static func framesMatch(
        marker: ScrollChromeScopeMarkerView,
        markerEndpoint: NSView,
        peer: ScrollChromeScopeMarkerView,
        peerEndpoint: NSView,
        candidate: NSScrollView
    ) -> Bool {
        let markerFrame = marker.convert(marker.bounds, to: nil)
        let peerFrame = peer.convert(peer.bounds, to: nil)
        let candidateFrame = candidate.convert(candidate.bounds, to: nil)
        // A marker with no laid-out bounds confirms no geometry — fail closed until layout.
        guard markerFrame.width > 0, markerFrame.height > 0 else { return false }
        guard frame(markerFrame, matches: peerFrame),
              frame(markerFrame, matches: markerEndpoint.convert(markerEndpoint.bounds, to: nil)),
              frame(markerFrame, matches: peerEndpoint.convert(peerEndpoint.bounds, to: nil))
        else { return false }
        // The candidate's full converted frame first — the existing raw equality. Only when that
        // fails does the final contentInsets fallback apply.
        if frame(markerFrame, matches: candidateFrame) { return true }
        guard let contentFrame = contentInsetFrame(of: candidate) else { return false }
        return frame(markerFrame, matches: contentFrame)
    }

    /// The candidate's content area: its bounds inset by its public `contentInsets`, converted
    /// through the candidate's own public coordinate conversion into the same window
    /// coordinates, with top/bottom applied per `isFlipped` — the flipped low-`y` edge is the
    /// visual top, otherwise the visual top is the high-`y` edge. Every inset must be finite and
    /// nonnegative, each edge possibly zero, and leave strictly positive inset bounds, so
    /// all-zero insets reproduce the full frame and add no fallback; negative, nonfinite or
    /// edge-sum-degenerate geometry returns nil and fails closed.
    @MainActor
    private static func contentInsetFrame(of candidate: NSScrollView) -> NSRect? {
        let insets = candidate.contentInsets
        let bounds = candidate.bounds
        guard insets.top.isFinite, insets.left.isFinite,
              insets.bottom.isFinite, insets.right.isFinite,
              insets.top >= 0, insets.left >= 0, insets.bottom >= 0, insets.right >= 0
        else { return nil }
        guard insets.left + insets.right < bounds.width,
              insets.top + insets.bottom < bounds.height
        else { return nil }
        let contentBounds = NSRect(
            x: bounds.minX + insets.left,
            y: bounds.minY + (candidate.isFlipped ? insets.top : insets.bottom),
            width: bounds.width - insets.left - insets.right,
            height: bounds.height - insets.top - insets.bottom
        )
        return candidate.convert(contentBounds, to: nil)
    }

    private static func frame(_ lhs: NSRect, matches rhs: NSRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= frameTolerance
            && abs(lhs.minY - rhs.minY) <= frameTolerance
            && abs(lhs.maxX - rhs.maxX) <= frameTolerance
            && abs(lhs.maxY - rhs.maxY) <= frameTolerance
    }
}

// MARK: - ScrollChromeScopeMarker

/// One half of a scope's marker pair. Each marker independently runs the bounded discovery
/// against its peer and holds its own attachment token through the single shared owner, so the
/// scoped scroll view carries two attachments: one marker churning (conditional replacement, sheet
/// re-presentation) never leaves the container without chrome while its peer still brackets it.
struct ScrollChromeScopeMarker: NSViewRepresentable {
    let pairID: ScrollChromeScopePairID
    /// The scope's identity relay, present only when the scope was installed with an
    /// `onNativeScrollView` handler; every marker still carries its own chrome token either way.
    var identityRelay: ScrollChromeScopeIdentityRelay?

    @MainActor
    final class Coordinator {
        var token: ScrollChromeToken?
        var frameCancellable: AnyCancellable?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ScrollChromeScopeMarkerView {
        let view = ScrollChromeScopeMarkerView(pairID: pairID)
        view.identityRelay = identityRelay
        view.setAccessibilityElement(false)
        view.onReconcile = { [weak coordinator = context.coordinator, weak view] in
            guard let view, let coordinator else { return }
            Self.reconcile(view: view, coordinator: coordinator)
        }
        // The marker's own frame-change notification is the bounded layout signal — no timers,
        // no KVO, no window scanning; the observation dies with the coordinator at dismantle.
        context.coordinator.frameCancellable = NotificationCenter.default
            .publisher(for: NSView.frameDidChangeNotification, object: view)
            .receive(on: DispatchQueue.main)
            .sink { [weak coordinator = context.coordinator, weak view] _ in
                guard let view, let coordinator else { return }
                Self.reconcile(view: view, coordinator: coordinator)
            }
        Self.reconcile(view: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: ScrollChromeScopeMarkerView, context: Context) {
        view.identityRelay = identityRelay
        Self.reconcile(view: view, coordinator: context.coordinator)
    }

    static func dismantleNSView(_ view: ScrollChromeScopeMarkerView, coordinator: Coordinator) {
        view.onReconcile = nil
        // The marker is going away: its discovery no longer vouches for any candidate, so the
        // relay sees nil from this half before the entry is purged as dead at delivery time.
        view.identityRelay?.report(nil, from: view)
        coordinator.frameCancellable?.cancel()
        coordinator.frameCancellable = nil
        if let token = coordinator.token {
            ScrollChromeOwner.detach(token)
            coordinator.token = nil
        }
    }

    /// One external scope event — mount, update, reparent, or the marker's own frame change —
    /// runs exactly the bounded synchronous reconciliation: no deferred pass, no timers, no
    /// polling, no KVO and no window scanning. A native chrome restyle that SwiftUI's own
    /// update/layout pass applies after this synchronous pass is answered by the shared owner's
    /// one public style observation, never by a rescan or retry here.
    @MainActor
    private static func reconcile(view: ScrollChromeScopeMarkerView, coordinator: Coordinator) {
        sync(view: view, coordinator: coordinator)
    }

    /// The single attach/dismantle decision point, always on the main actor: attach to the bounded
    /// marker-pair candidate while it is the same weakly identified scroll view with an enabled
    /// axis, re-assert the guarded chrome on unchanged identity, detach on reparent, discovery
    /// loss or off-window, and stay a documented no-op when the bounded rule isolates nothing.
    /// It runs synchronously for every external scope event.
    @MainActor
    private static func sync(view: ScrollChromeScopeMarkerView, coordinator: Coordinator) {
        guard view.window != nil else {
            if let token = coordinator.token {
                ScrollChromeOwner.detach(token)
                coordinator.token = nil
            }
            view.identityRelay?.report(nil, from: view)
            return
        }
        let scroll = ScrollChromeScopeDiscovery.candidate(around: view)
        // The same bounded fact feeds both halves of the scope: the chrome token decisions below
        // and the identity relay — the candidate (or its absence) is reported once, before any
        // chrome attach/detach branch can return.
        view.identityRelay?.report(scroll, from: view)
        if let token = coordinator.token {
            guard let scroll, scroll.hasVerticalScroller || scroll.hasHorizontalScroller else {
                ScrollChromeOwner.detach(token)
                coordinator.token = nil
                return
            }
            if token.owner.scrollView === scroll {
                token.owner.applyChrome()
                return
            }
            ScrollChromeOwner.detach(token)
            coordinator.token = nil
        }
        guard let scroll, scroll.hasVerticalScroller || scroll.hasHorizontalScroller else { return }
        coordinator.token = ScrollChromeOwner.attach(to: scroll)
    }
}

// MARK: - ScrollChromeScopeModifier

/// Brackets its content with the scope's two hidden markers: one behind the content, one in
/// front. Both fill exactly the content's bounds, so their converted frames must match the
/// scoped control's or container's own scroll view for discovery to accept it — by the scroll
/// view's full frame, or exactly by its bounds inset by its public contentInsets when its own
/// insets exclude part of the content area.
struct ScrollChromeScopeModifier: ViewModifier {
    /// One identity per scope instance, stable across body re-evaluations and shared by both
    /// markers, so nested scopes never pair across each other.
    @State private var pairID = ScrollChromeScopePairID()
    /// Aggregates the markers' discoveries for the optional handler; allocated once per scope
    /// instance. A scope without a handler passes nil to both markers and never touches it.
    @State private var identityRelay = ScrollChromeScopeIdentityRelay()
    let onNativeScrollView: ScrollChromeScopeNativeIdentityHandler?

    init(onNativeScrollView: ScrollChromeScopeNativeIdentityHandler? = nil) {
        self.onNativeScrollView = onNativeScrollView
    }

    func body(content: Content) -> some View {
        if let onNativeScrollView { identityRelay.install(handler: onNativeScrollView) }
        let relay = onNativeScrollView == nil ? nil : identityRelay
        return content
            .background { ScrollChromeScopeMarker(pairID: pairID, identityRelay: relay) }
            .overlay { ScrollChromeScopeMarker(pairID: pairID, identityRelay: relay) }
    }
}

// MARK: - View

extension View {
    /// Bounded component-local overlay scroll chrome for a TextEditor, a multiline TextField, or
    /// a List/Form container. The scoped content is bracketed by two hidden markers that must
    /// share one direct superview after at most one sole-child wrapper per endpoint is normalized,
    /// with exactly one candidate NSScrollView between their endpoint sibling
    /// indices (at most one wrapper level) and matching converted frames — the candidate's full
    /// frame, or exactly its bounds inset by its public `contentInsets` (its content area, with
    /// top/bottom applied per its flippedness, each inset finite and nonnegative and leaving
    /// positive inset bounds); anything else fails
    /// closed as a documented no-op — including a native text control with no dedicated
    /// NSScrollView. The shared field editor is never targeted. Applied to a List or Form the
    /// scope owns the container itself, so empty and virtualized containers keep their chrome.
    ///
    /// For ordinary `ScrollView`-backed containers prefer the document probe instead:
    /// `.background(ScrollChrome())` inside the scrolling document.
    ///
    /// When `onNativeScrollView` is supplied, the same bounded discovery additionally discloses
    /// the scoped container's own NSScrollView identity to that handler — the discovery result
    /// itself, or nil once every live marker isolates nothing. Delivery is deferred off layout,
    /// coalesced and deduplicated by scroll view and current document identity. Document replacement
    /// is disclosed on the next marker report; document changes alone do not schedule delivery.
    /// References are weak on both ends (a deallocated candidate is
    /// absent at the next reconciliation/report delivery), and never a broader search.
    /// Weak zeroing alone does not schedule delivery. Chrome ownership is unchanged either way, and
    /// omitting the handler keeps the scope's exact prior shape.
    public func scrollChromeScope(
        onNativeScrollView: ScrollChromeScopeNativeIdentityHandler? = nil
    ) -> some View {
        modifier(ScrollChromeScopeModifier(onNativeScrollView: onNativeScrollView))
    }
}

#if DEBUG
/// Dummy data — a scoped multiline editor and a scoped List container, both overflowing, so the
/// native overlay chrome is exercised; the List's rows are irrelevant to its scope by design.
private struct ScrollChromeScopePreview: View {
    @State private var instructions = """
    Scroll inside this editor — the native indicator fades at rest, and the editor's own scroller
    is small while any outer container keeps its own chrome. Editing, selection and IME are
    unchanged.
    """

    var body: some View {
        VStack(spacing: PbRadius.Metrics.spacing16) {
            TextEditor(text: $instructions)
                .font(.pb(.reading))
                .scrollChromeScope()
                .frame(height: PbRadius.Metrics.formRowHeight * 4)
                .clipShape(RoundedRectangle(cornerRadius: PbRadius.Metrics.formRadius))
            List(0 ..< 30, id: \.self) { row in
                Text("List row \(row) — the container keeps its scope while empty or virtualized.")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
            }
            .scrollChromeScope()
            .clipShape(RoundedRectangle(cornerRadius: PbRadius.Metrics.formRadius))
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(
            width: PbRadius.Metrics.formPreviewWidth * 2,
            height: PbRadius.Metrics.foundationHeight / 2
        )
        .background(Color.windowBG)
    }
}

#Preview("ScrollChromeScope - light") {
    ScrollChromeScopePreview().preferredColorScheme(.light)
}

#Preview("ScrollChromeScope - dark") {
    ScrollChromeScopePreview().preferredColorScheme(.dark)
}
#endif
