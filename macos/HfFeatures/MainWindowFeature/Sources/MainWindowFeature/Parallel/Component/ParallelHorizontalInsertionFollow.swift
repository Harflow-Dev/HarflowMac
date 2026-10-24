import AppKit

// MARK: - ParallelHorizontalConfiguration

struct ParallelHorizontalConfiguration {
    let workingColumnIDs: Set<String>
    let contextID: String
    var explicitNavigationID: String?
}

// MARK: - ParallelHorizontalInsertionFollow

/// Tracks insertion eligibility independently of delayed native document layout.
@MainActor
final class ParallelHorizontalInsertionFollow {
    struct Input {
        let previousIDs: [String]
        let ids: [String]
        let configuration: ParallelHorizontalConfiguration?
        let offset: CGFloat
        let isUserScrolling: Bool
    }

    private var contextID: String?
    private var navigationID: String?
    private var preLayoutOffset: CGFloat?
    private(set) var targetID: String?
    var isEnabled: Bool { contextID != nil }

    /// Returns whether the ordinary logical-anchor restoration remains eligible.
    func configure(_ input: Input) -> Bool {
        guard let configuration = input.configuration else {
            contextID = nil
            cancel()
            return true
        }
        let sameContext = contextID == configuration.contextID
        let navigationChanged = navigationID != configuration.explicitNavigationID
        contextID = configuration.contextID
        navigationID = configuration.explicitNavigationID
        guard sameContext, !navigationChanged else { cancel(); return false }
        let inserted = Set(input.ids).subtracting(input.previousIDs).intersection(configuration.workingColumnIDs)
        if !input.previousIDs.isEmpty, !inserted.isEmpty, input.offset <= 2, !input.isUserScrolling {
            targetID = input.ids.first { inserted.contains($0) }
        }
        if let targetID, !input.ids.contains(targetID) { cancel() }
        return true
    }

    func cancel() { targetID = nil; preLayoutOffset = nil }

    func rememberOffset(_ offset: CGFloat, layoutReady: Bool) {
        if layoutReady {
            preLayoutOffset = nil
        } else if preLayoutOffset == nil {
            preLayoutOffset = offset
        }
    }

    func consumeOffset(fallback: CGFloat) -> CGFloat {
        defer { preLayoutOffset = nil }
        return preLayoutOffset ?? fallback
    }

    /// Recognizes scoped horizontal navigation without consuming the native event.
    static func isHorizontalIntent(_ event: NSEvent, in scroll: NSScrollView) -> Bool {
        guard event.window === scroll.window else { return false }
        switch event.type {
        case .scrollWheel:
            return scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil))
                && (event.scrollingDeltaX != 0 || (event.modifierFlags.contains(.shift) && event.scrollingDeltaY != 0))
        case .leftMouseDown:
            guard let scroller = scroll.horizontalScroller, !scroller.isHidden else { return false }
            return scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil))
        case .keyDown:
            guard let responder = scroll.window?.firstResponder as? NSView,
                  responder === scroll || responder.isDescendant(of: scroll),
                  let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return false }
            return [UInt32(NSLeftArrowFunctionKey), UInt32(NSRightArrowFunctionKey), UInt32(NSHomeFunctionKey),
                    UInt32(NSEndFunctionKey), UInt32(NSPageUpFunctionKey), UInt32(NSPageDownFunctionKey)].contains(key)
        default: return false
        }
    }
}
