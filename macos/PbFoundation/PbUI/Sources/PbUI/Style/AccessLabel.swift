import Foundation

// MARK: - AccessLabel

/// Plain-language wording for a task's `freedom`.
public enum AccessLabel {
    /// "Read-only", "Can edit this repo", "Can publish" or "Full access"; an unrecognised value is
    /// returned as-is rather than guessed at.
    public static func text(freedom: String) -> String {
        switch freedom {
        case "read_only": "Read-only"
        case "write_in_repo": "Can edit this repo"
        case "publish": "Can publish"
        case "unrestricted": "Full access"
        default: freedom
        }
    }
}
