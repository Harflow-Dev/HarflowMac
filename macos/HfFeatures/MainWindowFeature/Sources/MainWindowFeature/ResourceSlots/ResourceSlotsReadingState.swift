import Observation
import SwiftUI

// MARK: - ResourceSlotsScrollGeometry

struct ResourceSlotsScrollGeometry: Equatable {
    let offset: CGFloat
    let contentHeight: CGFloat
    let viewportHeight: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(offset: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat, topInset: CGFloat = 0, bottomInset: CGFloat = 0) {
        self.offset = offset
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    var minimumOffset: CGFloat { -topInset }
    var maximumOffset: CGFloat { max(minimumOffset, contentHeight + bottomInset - viewportHeight) }
    func clamped(_ offset: CGFloat) -> CGFloat { min(maximumOffset, max(minimumOffset, offset)) }
}

// MARK: - ResourceSlotsReadingState

/// Coordinator-retained visual state. Presented frames bound restoration without a timer delay.
@Observable @MainActor
final class ResourceSlotsReadingState {
    static let maximumRestorationFrames = 8
    var position = ScrollPosition()
    var focusedRowID: String?
    private(set) var isRestoring = false
    private(set) var focusRestorationPending = false
    @ObservationIgnored private(set) var viewportHeight: CGFloat = 0
    @ObservationIgnored private(set) var retainedOffset: CGFloat = 0
    @ObservationIgnored private(set) var measuredOffset: CGFloat = 0
    @ObservationIgnored private var hasPosition = false
    @ObservationIgnored private var mounted = false
    @ObservationIgnored private var ready = true
    @ObservationIgnored private var requestedOffset: CGFloat?
    @ObservationIgnored private var latestGeometry: ResourceSlotsScrollGeometry?
    @ObservationIgnored private var restorationFrames = 0
    @ObservationIgnored private var focusFrames = 0
    @ObservationIgnored private var loadingActive = false
    @ObservationIgnored private var loadingAnnounced = false

    func beginAppearance(ready: Bool = true) {
        mounted = true
        self.ready = ready
        isRestoring = hasPosition
        requestedOffset = nil
        latestGeometry = nil
        restorationFrames = 0
        focusFrames = 0
        focusRestorationPending = focusedRowID != nil
    }

    func endAppearance() {
        mounted = false
        latestGeometry = nil
        isRestoring = false
        focusRestorationPending = false
    }

    func setReady(_ ready: Bool) {
        self.ready = ready
        if !ready { latestGeometry = nil }
    }

    func update(_ geometry: ResourceSlotsScrollGeometry, ready: Bool) {
        guard mounted else { return }
        self.ready = ready
        guard ready, geometry.viewportHeight > 0 else { latestGeometry = nil; return }
        latestGeometry = geometry
        viewportHeight = geometry.viewportHeight
        measuredOffset = geometry.offset
        if isRestoring {
            let target = geometry.clamped(retainedOffset)
            if requestedOffset == nil { request(target) }
            guard abs(geometry.offset - target) < 1 else { return }
            isRestoring = false
        }
        adopt(geometry)
    }

    /// Called by the attached view's display-link only while ready restoration/focus work remains.
    func presentedFrame() {
        guard mounted, ready else { return }
        guard let geometry = latestGeometry else {
            restorationFrames += 1
            if restorationFrames >= Self.maximumRestorationFrames {
                isRestoring = false
                focusRestorationPending = false
            }
            return
        }
        if isRestoring {
            restorationFrames += 1
            if restorationFrames >= Self.maximumRestorationFrames {
                adopt(geometry)
                isRestoring = false
                focusRestorationPending = false
                requestedOffset = nil
            } else if restorationFrames.isMultiple(of: 2) {
                request(geometry.clamped(retainedOffset))
            }
        } else if focusRestorationPending {
            focusFrames += 1
            if focusFrames >= Self.maximumRestorationFrames { focusRestorationPending = false }
        }
    }

    /// Tracking, direct manipulation and its deceleration take precedence over a return request.
    func cancelRestorationForUser() {
        guard mounted else { return }
        isRestoring = false
        focusRestorationPending = false
        requestedOffset = nil
        if let geometry = latestGeometry { adopt(geometry) }
    }

    func canRestoreFocus(rowID: String, frame: CGRect, geometryOffset: CGFloat? = nil) -> Bool {
        let currentFrame = geometryOffset.map { abs($0 - measuredOffset) < 1 } ?? true
        return mounted && !isRestoring && focusRestorationPending && focusedRowID == rowID && currentFrame
            && frame.width > 0 && frame.height > 0 && frame.maxY > 0 && frame.minY < viewportHeight
    }

    func didRestoreFocus() { focusRestorationPending = false }

    /// A new loading transition is a new announcement identity; remounting the same loading state is quiet.
    func takeLoadingAnnouncement(isLoading: Bool) -> Bool {
        guard isLoading else { loadingActive = false; return false }
        if !loadingActive { loadingActive = true; loadingAnnounced = false }
        guard !loadingAnnounced else { return false }
        loadingAnnounced = true
        return true
    }

    private func request(_ offset: CGFloat) {
        requestedOffset = offset
        position.scrollTo(y: offset)
    }

    private func adopt(_ geometry: ResourceSlotsScrollGeometry) {
        retainedOffset = geometry.clamped(geometry.offset)
        hasPosition = true
    }
}

// MARK: - ResourceSlotsOwnerFrames

/// Geometry cache has reference semantics but no observation; normal scrolling causes no view-state writes.
@MainActor
final class ResourceSlotsOwnerFrames {
    struct Entry {
        let frame: CGRect
        let offset: CGFloat
    }

    var values: [String: Entry] = [:]
}
