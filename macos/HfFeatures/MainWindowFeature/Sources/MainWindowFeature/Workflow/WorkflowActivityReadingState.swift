import Foundation

// MARK: - WorkflowActivityReadingState

/// Native input provenance is separate from document geometry. Layout never supplies intent.
struct WorkflowActivityReadingState {
    private(set) var following = true
    private(set) var offset: CGFloat = 0
    private(set) var pendingInput = false
    private(set) var liveScrolling = false
    private(set) var wheelTracking = false
    private(set) var momentum = false
    private(set) var scrollerTracking = false
    private(set) var upwardIntent = false

    var interacting: Bool { liveScrolling || wheelTracking || momentum || scrollerTracking || pendingInput }

    mutating func beginInput(upward: Bool) {
        pendingInput = true
        if upward {
            upwardIntent = true
            following = false
        }
    }

    mutating func consumeInput() { pendingInput = false }

    mutating func endInput(contentHeight: CGFloat, viewportHeight: CGFloat) {
        pendingInput = false
        settle(contentHeight: contentHeight, viewportHeight: viewportHeight)
    }

    mutating func setLiveScrolling(_ value: Bool) { liveScrolling = value }
    mutating func setWheelTracking(_ value: Bool) { wheelTracking = value }
    mutating func setMomentum(_ value: Bool) { momentum = value }
    mutating func setScrollerTracking(_ value: Bool) { scrollerTracking = value }

    mutating func userPosition(_ value: CGFloat, upward: Bool, downward: Bool? = nil) {
        if upward {
            upwardIntent = true
            following = false
        } else if downward ?? (value > offset + 0.5) {
            upwardIntent = false
        }
        offset = max(0, value)
        pendingInput = false
    }

    mutating func settle(contentHeight: CGFloat, viewportHeight: CGFloat) {
        guard !interacting else { return }
        if contentHeight <= viewportHeight {
            upwardIntent = false
            following = true
        } else if !upwardIntent, contentHeight - offset - viewportHeight <= 24 {
            following = true
        }
    }

    mutating func positioned(at value: CGFloat) { offset = max(0, value) }
    mutating func resumeFollowing() {
        upwardIntent = false
        following = true
    }

    mutating func endInteractions() {
        pendingInput = false
        liveScrolling = false
        wheelTracking = false
        momentum = false
        scrollerTracking = false
    }
}
