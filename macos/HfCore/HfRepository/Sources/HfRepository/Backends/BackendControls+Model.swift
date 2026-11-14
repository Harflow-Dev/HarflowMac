import Foundation

// MARK: - BackendControls + model effort

public extension BackendControls {

    /// The controls for one harness as narrowed by the chosen model's own effort levels.
    ///
    /// Only the effort control can change, and only when the harness reports selectable levels
    /// (`.levels`). A model that reports no levels (`nil`) leaves the harness controls unchanged; one that
    /// reports an empty list leaves no selectable level (`.unsupported`); a non-empty list keeps the
    /// harness levels the model also lists, in the harness's order, and an empty intersection is
    /// `.unsupported`. The model never widens a harness: an `.unknown` or `.unsupported` harness effort
    /// stays as it is, so cached model facts cannot outlive a degraded, absent or changed harness.
    static func effectiveControls(harness: BackendControls, modelEffortLevels: [String]?) -> BackendControls {
        guard let modelEffortLevels, case .levels(let harnessLevels) = harness.effort else { return harness }
        let allowed = Set(modelEffortLevels)
        let intersection = harnessLevels.filter { allowed.contains($0) }
        return BackendControls(
            model: harness.model, effort: intersection.isEmpty ? .unsupported : .levels(intersection), turnCap: harness.turnCap
        )
    }
}
