import CoreGraphics
import Foundation

// MARK: - ParallelViewportClaims

/// Which inspector views drive the viewport: the newest live view that has measured a width wins.
///
/// A view registers once, at the rank of its first claim or report. A view that has gone away is remembered with its last
/// geometry and can only come back through a new claim (a genuine reappearance), never through a late report.
struct ParallelViewportClaims {
    /// How many released views are remembered.
    static let endedCapacity = 16

    private struct Entry {
        var rank: Int
        var width: CGFloat?
        var offset: CGFloat
    }

    private struct Ended {
        var token: UUID
        var width: CGFloat?
        var offset: CGFloat
    }

    private var live: [UUID: Entry] = [:]
    private var ended: [Ended] = []
    private var nextRank = 0
    private var heldWidth: CGFloat = 0
    private var heldOffset: CGFloat = 0

    /// The viewport width to apply: the newest measured live view's, held while live views exist but none has measured, else 0.
    var effectiveWidth: CGFloat { heldWidth }

    /// The viewport offset that goes with `effectiveWidth`.
    var effectiveOffset: CGFloat { heldOffset }

    /// The highest-ranked live view that has measured a width.
    var owner: UUID? { measuredOwner }

    /// Whether `token` has been released and not claimed again.
    func hasEnded(_ token: UUID) -> Bool { ended.contains { $0.token == token } }

    private var measuredOwner: UUID? {
        live.filter { $0.value.width != nil }.max { $0.value.rank < $1.value.rank }?.key
    }

    /// Registers `token` without geometry. A live token is left alone; an ended one is revived with its last geometry.
    mutating func claim(_ token: UUID) {
        guard live[token] == nil else { return }
        if let index = ended.firstIndex(where: { $0.token == token }) {
            let old = ended.remove(at: index)
            live[token] = Entry(rank: newRank(), width: old.width, offset: old.offset)
        } else {
            live[token] = Entry(rank: newRank(), width: nil, offset: 0)
        }
        refresh()
    }

    /// Records a measurement. Returns false, changing nothing, for a view that has gone away.
    @discardableResult
    mutating func report(_ token: UUID, offset: CGFloat, width: CGFloat) -> Bool {
        guard !hasEnded(token) else { return false }
        var entry = live[token] ?? Entry(rank: newRank(), width: nil, offset: 0)
        entry.width = width
        entry.offset = offset
        live[token] = entry
        refresh()
        return true
    }

    /// Ends `token`, whether or not it is registered, remembering its last geometry.
    mutating func release(_ token: UUID) {
        let last = live[token]
        let previous = ended.first { $0.token == token }
        ended.removeAll { $0.token == token }
        ended.append(Ended(token: token, width: last?.width ?? previous?.width, offset: last?.offset ?? previous?.offset ?? 0))
        if ended.count > Self.endedCapacity { ended.removeFirst(ended.count - Self.endedCapacity) }
        live[token] = nil
        refresh()
    }

    /// Forgets every live view and the held geometry; released views stay released.
    mutating func reset() {
        live.removeAll()
        heldWidth = 0
        heldOffset = 0
    }

    private mutating func newRank() -> Int {
        nextRank += 1
        return nextRank
    }

    private mutating func refresh() {
        if let key = measuredOwner, let entry = live[key], let width = entry.width {
            heldWidth = width
            heldOffset = entry.offset
        } else if live.isEmpty {
            heldWidth = 0
            heldOffset = 0
        }
    }
}

// MARK: - Viewport ownership

extension ParallelVM {
    /// The view that currently drives the viewport.
    var viewportOwner: UUID? { viewportClaims.owner }

    /// Registers a view that appeared, without geometry. A reappearing view that was released is revived with its last geometry.
    ///
    /// The workflow inspector view that drives the viewport can be replaced in place: the new view reports before the old one
    /// disappears, so an older or released view must never zero or override the newest measured one.
    func claimViewport(owner: UUID) {
        viewportClaims.claim(owner)
        applyClaimedViewport()
    }

    /// Records the view's measurement, then applies the newest measured live view's geometry. Ignored for a released view.
    func updateViewport(owner: UUID, offset: CGFloat, width: CGFloat) {
        guard viewportClaims.report(owner, offset: offset, width: width) else { return }
        applyClaimedViewport()
    }

    /// Ends the view, then applies what remains: another live view's last width, or 0 when none has measured.
    func releaseViewport(owner: UUID) {
        viewportClaims.release(owner)
        applyClaimedViewport()
    }

    private func applyClaimedViewport() {
        updateViewport(offset: viewportClaims.effectiveOffset, width: viewportClaims.effectiveWidth)
    }
}
