import Foundation

// MARK: - HarnessQualificationModel

/// Complete immutable card presentation, prepared by a feature VM before main-actor application.
public struct HarnessQualificationModel: Equatable, Sendable {
    /// UI attempt state; cancellation means result adoption stopped, not engine termination.
    public enum State: String, CaseIterable, Sendable {
        /// No qualification check has been adopted.
        case notChecked
        /// An explicit qualification attempt is in progress.
        case checking
        /// Required qualification evidence is ready.
        case ready
        /// A required check failed.
        case failed
        /// A runtime failure invalidated earlier evidence.
        case failedAtRuntime
        /// The harness or evidence is unavailable.
        case unavailable
        /// The engine or feature does not support qualification.
        case unsupported
        /// The UI stopped adopting this attempt; engine completion is unknown.
        case cancelled
        /// The selected binary changed and requires fresh evidence.
        case binaryChanged

        /// Accessible display label for this state.
        public var title: String {
            switch self {
            case .notChecked: "Not checked"
            case .checking: "Qualifying"
            case .ready: "Ready"
            case .failed: "Failed"
            case .failedAtRuntime: "Failed at runtime"
            case .unavailable: "Harness unavailable"
            case .unsupported: "Unsupported engine"
            case .cancelled: "Cancelled"
            case .binaryChanged: "Binary changed"
            }
        }

        /// Explicit check, retry, or cancellation action; nil when unavailable.
        public var actionTitle: String? {
            switch self {
            case .checking: "Cancel check"
            case .ready: "Check again"
            case .unavailable, .unsupported: nil
            case .notChecked, .binaryChanged: "Check harness"
            case .failed, .failedAtRuntime, .cancelled: "Retry qualification"
            }
        }
    }

    /// One displayed feature; source and reason must come from public engine evidence.
    public struct Feature: Equatable, Identifiable, Sendable {
        /// Stable engine feature or candidate identifier.
        public let id: String
        /// Displayed outcome and engine evidence source.
        public let result: String
        /// Failure or evidence detail, bounded to 1,000 characters.
        public let reason: String
        /// Creates one feature presentation with bounded evidence detail.
        public init(id: String, result: String, reason: String = "") {
            self.id = id
            self.result = result
            self.reason = String(reason.prefix(1000))
        }
    }

    /// Installed harness/version label supplied by the feature view model.
    public let identity: String
    /// Whether cached discovery has settled enough to offer an explicit check action.
    public let canCheck: Bool
    /// Optional scope-specific action wording; unavailable states still expose no action.
    public let actionTitleOverride: String?
    /// Effective action label, preserving the state's unavailable and unsupported gates.
    public var actionTitle: String? { state.actionTitle.map { actionTitleOverride ?? $0 } }
    /// Current card state chosen by its feature view model.
    public let state: State
    /// Summary explaining the current qualification state.
    public let message: String
    /// Ordered feature rows prepared by the owning feature view model.
    public let features: [Feature]
    /// Failure or evidence detail, bounded to 1,000 characters.
    public let reason: String

    /// Creates a complete card presentation and bounds its failure detail.
    public init(identity: String, state: State, message: String, features: [Feature], reason: String = "",
                canCheck: Bool = true, actionTitleOverride: String? = nil) {
        self.identity = identity
        self.canCheck = canCheck
        self.actionTitleOverride = actionTitleOverride
        self.state = state
        self.message = message
        self.features = features
        self.reason = String(reason.prefix(1000))
    }
}
