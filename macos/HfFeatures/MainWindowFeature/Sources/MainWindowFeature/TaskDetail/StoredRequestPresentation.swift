import HfRepository
import MonitorCore

// MARK: - StoredRequestPresentation

/// Assignment text and actions remain qualified independently from captured display events.
struct StoredRequestPresentation: Equatable {
    let heading: String
    let text: String?
    let provenance: String?
    let copyLabel: String?
    let readMoreBytes: Int?
    let isFull: Bool

    init(state: TaskRequestReadState) {
        guard case let .received(value, maxBytes) = state else {
            self.heading = if case .failed = state { "Original request unavailable" } else { "Original request · loading" }
            self.text = nil
            self.provenance = nil
            self.copyLabel = nil
            self.readMoreBytes = nil
            self.isFull = false
            return
        }
        let failed = value.state == .integrityFailed || value.integrity == .failed
        let permitted = !failed && value.state != .unavailable
        self.isFull = value.state == .available && value.complete && !value.truncated
            && (value.integrity == .verified || value.integrity == .notApplicable)
        self.text = permitted ? value.text : nil
        self.heading = failed ? "Original request · integrity check failed"
            : value.state == .unavailable ? "Original request unavailable"
            : value.state == .previewOnly ? "Request preview"
            : isFull ? "Original request" : "Partial request"
        self.provenance = isFull ? (value.integrity == .verified ? "Verified stored request" : "Complete stored request")
            : value.state == .previewOnly ? "Preview · not the full assignment"
            : value.integrity == .unverified ? "Unverified text · completeness unknown" : "Bounded request prefix"
        self.copyLabel = text == nil ? nil : isFull ? "Copy original request" : value.state == .previewOnly ? "Copy preview" : "Copy displayed text"
        self.readMoreBytes = text != nil && !isFull && maxBytes < 131072 ? 131072 : nil
    }
}
