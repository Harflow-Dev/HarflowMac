import MonitorCore

// MARK: - WorkflowValidationState

/// Presentation of the latest validation attempt; Save also requires exact definition equality.
enum WorkflowValidationState: Equatable, Sendable {
    case inactive
    case nameRequired
    case checking
    case valid
    case invalid(String)
    case unavailable(String)

    var message: String? {
        switch self {
        case .inactive, .valid: nil
        case .nameRequired: "Enter a workflow name."
        case .checking: "Checking workflow…"
        case let .invalid(reason): reason
        case let .unavailable(reason): "Unable to validate workflow. " + reason
        }
    }

    var saveAccessibilityLabel: String {
        if case .invalid = self { return "Save, fix the problem first" }
        return "Save"
    }

    var accessibilityLabel: String {
        switch self {
        case .inactive: "Workflow editor"
        case .nameRequired: "Name required"
        case .checking: "Checking workflow"
        case .valid: "Workflow valid"
        case .invalid: "Workflow invalid"
        case .unavailable: "Validation unavailable"
        }
    }

    var glyph: TaskStatus? {
        switch self {
        case .checking: .running
        case .invalid, .unavailable: .failed
        case .inactive, .nameRequired, .valid: nil
        }
    }
}
