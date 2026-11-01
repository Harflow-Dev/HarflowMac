import SwiftUI

// MARK: - ResourceSlotsScrollGeometry

struct ResourceSlotsScrollGeometry: Codable, Equatable, Sendable {
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

// MARK: - ResourceSlotsScrollTarget

/// Group and owner identifiers occupy independent namespaces in the native target layout.
enum ResourceSlotsScrollTarget: Codable, Hashable, Sendable {
    case group(String)
    case owner(String)
}

extension ResourceSlotsGroup {
    var scrollTarget: ResourceSlotsScrollTarget { .group(id) }
}

extension ResourceSlotsOwner {
    var scrollTarget: ResourceSlotsScrollTarget { .owner(id) }
}

// MARK: - ResourceSlotsDiagnosticRecord

/// Opt-in synthetic-fixture observations. Consumers own bounded buffering and serialization.
struct ResourceSlotsDiagnosticRecord: Codable, Equatable, Sendable {
    enum Category: String, Codable, Sendable { case transition, geometry }
    enum FinishReason: String, Codable, Sendable { case success, boundaryAligned, boundedFallback, userCancellation, unmount, runtimeChange }
    struct TargetFrame: Codable, Equatable, Sendable {
        let viewport: CGRect
        let measurementOffset: CGFloat
        let content: CGRect?
    }

    let sequence: UInt64
    let event: String
    let category: Category
    let phase: String
    let generation: UUID
    let idScrollRequest: ResourceSlotsIDScrollRequest?
    let idRequestCount: Int
    let targetIDAttemptCount: Int
    let discoverySettledFrames: Int
    let idRequestTrigger: String?
    let idRequestBaseline: CGFloat?
    let idRequestContentHeight: CGFloat?
    let restorationFrames: Int
    let focusFrames: Int
    let pointRequestCount: Int
    let maximumPointRequests: Int
    let outcome: ResourceSlotsRestorationOutcome?
    let maximumRestorationFrames: Int
    let selected: Bool
    let mounted: Bool
    let ready: Bool
    let isRestoring: Bool
    let retainedOffset: CGFloat
    let measuredOffset: CGFloat
    let anchor: ResourceSlotsReadingState.Anchor?
    let previousAnchor: ResourceSlotsReadingState.Anchor?
    let mountRestorationTarget: ResourceSlotsReadingState.Anchor?
    let mountRestorationOffset: CGFloat?
    let mountTargetGroupFrame: TargetFrame?
    let callbackGroupID: String?
    let cachedGroupCount: Int
    let commandContentHeight: CGFloat?
    let requestedTarget: ResourceSlotsScrollTarget?
    let requestedOffset: CGFloat?
    let geometry: ResourceSlotsScrollGeometry?
    let callbackGeometry: ResourceSlotsScrollGeometry?
    let ownerFrame: TargetFrame?
    let groupFrame: TargetFrame?
    let callbackTarget: ResourceSlotsScrollTarget?
    let callbackViewportFrame: CGRect?
    let callbackContentFrame: CGRect?
    let viewportCoordinateSpace: String
    let contentCoordinateSpace: String
    let coordinateSpaceDelta: CGFloat
    let rejection: String?
    let focusedRowID: String?
    let confirmedFocusID: String?
    let focusReturnAuthorized: Bool
    let focusRestorationPending: Bool
    let finishReason: FinishReason?
}

// MARK: - ResourceSlotsDiagnosticFrames

struct ResourceSlotsDiagnosticFrames: Equatable {
    let viewport: CGRect
    let content: CGRect?
}

// MARK: - ResourceSlotsIDScrollRequest

struct ResourceSlotsIDScrollRequest: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let generation: UUID
    let target: ResourceSlotsScrollTarget
}

// MARK: - ResourceSlotsFocusReturnRequest

/// A single-use native focus restoration intent, issued per Back cycle. Only the control that
/// actually holds first responder with this same token may consume it; every deferred focus
/// observation carries the token it was captured with so a stale callback is recognisable.
struct ResourceSlotsFocusReturnRequest: Equatable, Sendable {
    let token: UUID
    let rowID: String
}

// MARK: - ResourceSlotsRestorationOutcome

enum ResourceSlotsRestorationOutcome: String, Codable, Sendable {
    case exact, boundaryAligned, fallback, userCancelled
}

// MARK: - ResourceSlotsFrameDiagnosticContext

struct ResourceSlotsFrameDiagnosticContext {
    let mounted: Bool
    let selected: Bool
    let ready: Bool
    let targetExists: Bool
    let viewportHeight: CGFloat
    let geometry: ResourceSlotsScrollGeometry?
    let coordinateSpaceDelta: CGFloat

    func rejection(frames: ResourceSlotsDiagnosticFrames) -> String? {
        if !mounted { return "unmounted" }
        if !selected { return "unselected" }
        if !ready { return "not-ready" }
        if frames.viewport.width <= 0 || frames.viewport.height <= 0 { return "nonpositive-size" }
        if !targetExists { return "target-removed" }
        guard let content = frames.content else { return "missing-content-frame" }
        if let geometry, abs(content.minY - frames.viewport.minY - coordinateSpaceDelta - geometry.offset) >= 1 {
            return "incoherent-offset"
        }
        if frames.viewport.maxY <= 0 || frames.viewport.minY >= viewportHeight { return "offscreen" }
        return nil
    }
}

extension ResourceSlotsDiagnosticFrames {
    func coherentViewport(geometry: ResourceSlotsScrollGeometry, coordinateSpaceDelta: CGFloat) -> CGRect? {
        guard let content, viewport.width > 0, viewport.height > 0,
              abs((content.minY - viewport.minY) - coordinateSpaceDelta - geometry.offset) < 1 else { return nil }
        return content.offsetBy(dx: viewport.minX - content.minX, dy: -geometry.offset - coordinateSpaceDelta)
    }

    static func pendingReason(frames: Self?, geometry: ResourceSlotsScrollGeometry, coordinateSpaceDelta: CGFloat, pending: Bool) -> String {
        if pending { return "pending-command" }
        guard let frames else { return "absent" }
        guard let viewport = frames.coherentViewport(geometry: geometry, coordinateSpaceDelta: coordinateSpaceDelta) else { return "incoherent" }
        return viewport.resourceSlotsIntersects(viewportHeight: geometry.viewportHeight) ? "settling" : "nonvisible"
    }
}

extension CGRect {
    func resourceSlotsIntersects(viewportHeight: CGFloat) -> Bool { width > 0 && height > 0 && maxY > 0 && minY < viewportHeight }
}

// MARK: - ResourceSlotsReadingAnchor

struct ResourceSlotsReadingAnchor: Codable, Equatable, Sendable {
    let groupID: String
    let rowID: String?
    let relativeY: CGFloat
}

// MARK: - ResourceSlotsRestorationSample

struct ResourceSlotsRestorationSample: Equatable {
    let geometry: ResourceSlotsScrollGeometry
    let frames: ResourceSlotsDiagnosticFrames?
}
