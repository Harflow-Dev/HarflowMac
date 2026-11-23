import Foundation

// MARK: - MissingFeature

/// The plain sentence a screen shows when the selected runtime does not advertise a feature that
/// screen needs. It names no command, socket or daemon and offers no reinstall action.
public enum MissingFeature {

    /// "This Harflow runtime can't <canDo>. Update Harflow to use it."
    /// - Parameter canDo: What the screen cannot do, as a verb phrase ("inspect the task store").
    public static func sentence(canDo: String) -> String {
        "This Harflow runtime can't \(canDo). Update Harflow to use it."
    }
}
