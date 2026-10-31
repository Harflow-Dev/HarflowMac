import Foundation

// Values are prepared by the feature mapper; views do not derive inventory semantics.
struct ResourceSlotsPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case loading
        case ready(summary: String, groups: [ResourceSlotsGroup])
        case empty(title: String, message: String)
        case notEnabled(title: String, message: String)
        case unsupported(title: String, message: String)
        case unavailable(title: String, message: String)
    }

    let state: State
    let qualifiers: [ResourceSlotsQualifier]
}

struct ResourceSlotsQualifier: Equatable, Sendable, Identifiable {
    let id: String
    let text: String
    let isWarning: Bool
}

struct ResourceSlotsGroup: Equatable, Sendable, Identifiable {
    let id: String
    let title: String
    let capacitySummary: String
    let holderHeading: String
    let holders: [ResourceSlotsOwner]
    let emptyHolderMessage: String?
    let waiterHeading: String?
    let waiters: [ResourceSlotsOwner]
}

struct ResourceSlotsOwner: Equatable, Sendable, Identifiable {
    struct Action: Equatable, Sendable {
        let label: String
        let ownerID: String
    }

    let id: String
    let title: String
    let ownerID: String
    let status: String
    let since: String?
    let detail: String?
    let position: String?
    let action: Action?
    let blockers: ResourceSlotsBlockers?
}

struct ResourceSlotsBlockers: Equatable, Sendable {
    let rows: [ResourceSlotsBlocker]
    let note: String?
}

struct ResourceSlotsBlocker: Equatable, Sendable, Identifiable {
    let id: String
    let text: String
}
