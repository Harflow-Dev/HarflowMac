import AppKit

// MARK: - ParallelScrollAnchorProvider

/// A reading-anchored surface's contribution to native scroll observation. An armed provider
/// owns the vertical position across a structural document change: the observer asks it for an
/// immediate target computed from fresh native geometry before the observer reports, and the
/// provider's target supersedes any SwiftUI numeric restoration request measured before the
/// change. The observer holds it weakly and knows nothing about the anchor it tracks — no
/// surface-specific types cross this seam.
@MainActor
protocol ParallelScrollAnchorProvider: AnyObject {
    var isAnchorRestorationActive: Bool { get }
    var ownsNumericRestoration: Bool { get }
    /// The provider's current semantic vertical target for the adopted document, or nil while
    /// no armed reference matches the document's state. Called on the scroll observer's own
    /// attach and document-frame notification paths, before the position is reported.
    func immediateAnchorTarget(document: NSView) -> CGFloat?
    /// Irreversibly ends the provider's armed reference: real user intent in either direction,
    /// a replaced, detached or disappeared native target. A cancelled provider never re-arms.
    func cancelAnchorRestoration()
}

extension ParallelScrollAnchorProvider {
    var isAnchorRestorationActive: Bool { true }
    var ownsNumericRestoration: Bool { false }
}

// MARK: - ParallelScrollNativeIdentity

/// Main-actor holder wiring one scoped container's disclosed native scroll identity to this
/// observer's observation view — the bounded path a List-backed feed needs: its own NSScrollView
/// is not reachable as the representable's `enclosingScrollView` (the observation view must sit
/// outside the marker pair, and inside a virtualized row it would die with the row), so the
/// identity comes from PbUI's strict marker-pair discovery instead.
///
/// The holder never defers on its own: the scope relay's single generation-guarded main-queue
/// delivery is the only asynchrony, so an unmounted or replaced observation view is exactly a
/// weak miss — no stale attach callback can reach a dead view. Registration re-delivers the last
/// known identity so a queued restoration survives the observation view's own initial mount, and
/// an explicit nil detaches the observation view's native notifications and wheel monitor — fail
/// closed, never a fallback to any enclosing scroll view.
@MainActor
final class ParallelScrollNativeIdentity {
    private weak var observationView: ParallelScrollObservationView?
    /// The last identity the scope relay delivered — weak, so a scoped scroll view that
    /// deallocated reads as nil on the observation view's next registration.
    private weak var knownScrollView: NSScrollView?
    private weak var knownDocument: NSView?
    private weak var currentAnchorProvider: ParallelScrollAnchorProvider?
    private var ownsAnchorProvider = false

    /// Publishes a new native lease synchronously. A queued representable update carrying an
    /// older token cannot replace this coordinator's current provider.
    func setAnchorProvider(_ provider: ParallelScrollAnchorProvider?) {
        ownsAnchorProvider = true
        currentAnchorProvider = provider
        observationView?.anchorProvider = provider
    }

    /// A completed state callback may publish a coherent candidate after its frame notification.
    /// Reevaluate only the current provider against the currently adopted native document.
    func reevaluateAnchorProvider(_ provider: ParallelScrollAnchorProvider) {
        guard currentAnchorProvider === provider, provider.isAnchorRestorationActive,
              knownScrollView?.documentView === knownDocument else { return }
        observationView?.reevaluateAnchorProvider(provider)
    }

    func resolvedAnchorProvider(fallback: ParallelScrollAnchorProvider?) -> ParallelScrollAnchorProvider? {
        ownsAnchorProvider ? currentAnchorProvider : fallback
    }

    /// Registers the observation view — also re-registering it after a representable remount —
    /// and immediately delivers the last known identity, so a scroll view disclosed before the
    /// observation view mounted still attaches once it exists.
    func register(_ view: ParallelScrollObservationView) {
        observationView = view
        if ownsAnchorProvider { view.anchorProvider = currentAnchorProvider }
        view.adoptNativeIdentity(knownScrollView)
    }

    /// Releases the observation view at representable dismantle; the dying view detaches its own
    /// subscriptions and wheel monitor.
    func unregister(_ view: ParallelScrollObservationView) {
        guard observationView === view else { return }
        observationView = nil
    }

    /// The scope relay's delivery point: pushes the disclosed identity straight to the weakly
    /// held observation view — direct adoption that bypasses `configure`'s unchanged-input early
    /// return, so a discovered or replaced target attaches and reports even when nothing else
    /// changed.
    @discardableResult
    func deliver(_ scrollView: NSScrollView?) -> Bool {
        let changed = knownScrollView !== scrollView || knownDocument !== scrollView?.documentView
        knownScrollView = scrollView
        knownDocument = scrollView?.documentView
        observationView?.adoptNativeIdentity(scrollView)
        return changed
    }

    /// A cancellation may retire a newer owner generation only through its live scoped binding.
    func isCurrentBinding(observer: ParallelScrollObservationView, scrollView: NSScrollView) -> Bool {
        observationView === observer && knownScrollView === scrollView
            && knownDocument != nil && knownDocument === scrollView.documentView
    }

    /// Identity matching for cached native measurements: whether the document view a sample was
    /// measured in is the one the scoped relay currently discloses. A sample that fails this
    /// check belongs to a replaced (or already deallocated) native target and must be rejected,
    /// never scaled onto a new viewport.
    func isCurrentDocument(_ document: NSView?) -> Bool {
        guard let document else { return false }
        return knownScrollView?.documentView === document
    }
}
