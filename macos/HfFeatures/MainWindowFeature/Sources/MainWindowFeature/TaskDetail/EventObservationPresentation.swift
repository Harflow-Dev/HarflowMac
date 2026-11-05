import Foundation
import HfRepository
import MonitorCore

extension EventObservationFrame {
    var presentationAvailability: EventAvailability {
        if history.isLoading { return .loading }
        return history.reasons.isEmpty && history.currentness == .current ? .available : .unavailable
    }

    var presentationHistory: EventHistoryState {
        EventHistoryState(hasMore: history.availableActions.contains(.loadEarlier), isLoading: history.isLoading,
            error: history.failure?.message ?? (history.reasons.isEmpty ? nil : history.reasons.map(\.presentationText).sorted().joined(separator: ", ")),
            generation: revision)
    }
}

extension EventObservationReason {
    var presentationText: String {
        switch self {
        case .normalizationLoss: "Some captured content could not be represented"
        case .skippedRecords: "Some captured records were skipped"
        case .gaps: "Capture gap"
        case .captureUnavailable: "Captured history unavailable"
        case .unknownKind: "Unsupported event kind; inspect Events"
        case .unsupportedPayload: "Unsupported event content; inspect Events"
        case .ambiguousOrder: "Captured record order is ambiguous"
        case .ambiguousCall: "Tool call relationships are ambiguous"
        case .capacity: "This view's activity limit has been reached"
        case .historicalLimit: "Earlier history is outside this view's read limit"
        case .nonprogress: "History paused; the read made no progress"
        case .requestUnavailable: "Captured history read unavailable"
        case .unavailable: "History read unavailable"
        case .resetExhausted: "This observation reached its recovery limit. Reopen the view to begin a new observation."
        }
    }
}
