import Foundation
import HfRepository
import MonitorCore

// MARK: - GeneralSettingsGroup

/// The groups of the General tab, in display order (HarflowDesign `e1c9230`, `settings/general`).
enum GeneralSettingsGroup: CaseIterable, Equatable {
    case appearance
    case behaviour
    case runtime
    case taskStore

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .behaviour: "Behaviour"
        case .runtime: "Harflow runtime"
        case .taskStore: "Task store"
        }
    }
}

// MARK: - AppearanceOption

/// The theme segments, in the design's explicit order. Not `AppAppearance.allCases`, whose order is not the design's.
enum AppearanceOption {
    static let segments: [(value: AppAppearance, title: String)] = [
        (.system, "System"), (.light, "Light"), (.dark, "Dark")
    ]
}

// MARK: - RowGlyph

/// The glyph drawn at the start of a Settings status row. `status` maps it onto the shared task status glyphs.
enum RowGlyph: Equatable {
    case busy
    case done
    case failed
    case attention
    /// A cancelled qualification check: the shared stop glyph.
    case cancelled
    /// A harness that was not found: the cross in the cancelled colour.
    case unavailable

    /// The shared task status whose glyph this one reuses; nil for the glyphs drawn here (attention, unavailable).
    var status: TaskStatus? {
        switch self {
        case .busy: .running
        case .done: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .attention, .unavailable: nil
        }
    }

    /// The SF Symbol drawn for attention.
    var attentionSymbol: String? { self == .attention ? "exclamationmark.circle" : nil }

    /// The SF Symbol drawn for a harness that was not found, in the neutral colour.
    var unavailableSymbol: String? { self == .unavailable ? "xmark" : nil }

    /// The spoken label.
    var accessibilityLabel: String {
        switch self {
        case .busy: "In progress"
        case .done: "Done"
        case .failed: "Failed"
        case .attention: "Needs attention"
        case .cancelled: "Cancelled"
        case .unavailable: "Not found"
        }
    }
}

// MARK: - RuntimeRowPresentation

/// The Harflow runtime row: a glyph, the title, the detail and an optional action.
struct RuntimeRowPresentation: Equatable {
    let glyph: RowGlyph?
    let title: String
    let detail: String
    let actionTitle: String?

    init(state: RuntimeSetupState) {
        self.title = state.title
        self.detail = state.detail
        self.actionTitle = state.actionTitle
        self.glyph = switch state {
        case .checking, .installing, .updating: .busy
        case .failed, .updateFailed: .failed
        case .ready: .done
        case .installationRequired: nil
        }
    }
}
