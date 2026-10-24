import Foundation

// MARK: - AppAppearance

/// The appearance requested by the person for the whole application.
public enum AppAppearance: String, CaseIterable, Equatable, Sendable, Identifiable {
    case light
    case dark
    case system

    public var id: String { rawValue }
}
