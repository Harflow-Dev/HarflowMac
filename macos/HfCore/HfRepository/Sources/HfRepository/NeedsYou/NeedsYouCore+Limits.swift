import Foundation

// MARK: - NeedsYouCore limits and output

extension NeedsYouCore {
    struct Output {
        let revision: Int
        let snapshot: NeedsYouSnapshot
        let events: [NeedsYouEvent]
    }

    /// Process launches per pass. `CtlClient` launches a `version-info` handshake before every command, so a
    /// command costs `launchesPerCommand`; the budget is therefore about 24 commands.
    static let invocationBudget = 48
    static let launchesPerCommand = 2
    static let inventoryLaunchBudget = 20
    static let maxStatusReads = 12
    static let maxWorkflowPages = 6
    static let maxTaskPages = 4
    static let suppressionSeconds: TimeInterval = 60

}
