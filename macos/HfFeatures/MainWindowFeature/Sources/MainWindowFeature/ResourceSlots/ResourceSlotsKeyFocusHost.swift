import AppKit

// MARK: - ResourceSlotsKeyFocusHost

/// The reading state's view of the hosting window's keyboard focus at Back. A struct of closures,
/// so the authorization rules can be checked without a window.
@MainActor
struct ResourceSlotsKeyFocusHost {
    /// Whether a hosting window is recorded.
    var hasWindow: () -> Bool
    /// The window's current first responder.
    var currentResponder: () -> NSResponder?
    /// The window itself as a responder.
    var windowResponder: () -> NSResponder?
    /// Resigns the first responder to the window; `false` when the responder refuses.
    var resign: () -> Bool

    /// Reads the state's weak hosting window through the state on every call and never captures it.
    static func production(for state: ResourceSlotsReadingState) -> ResourceSlotsKeyFocusHost {
        .init(hasWindow: { [weak state] in state?.focusReturnHostWindow != nil },
              currentResponder: { [weak state] in state?.focusReturnHostWindow?.firstResponder },
              windowResponder: { [weak state] in state?.focusReturnHostWindow },
              resign: { [weak state] in state?.focusReturnHostWindow?.makeFirstResponder(nil) ?? false })
    }
}
