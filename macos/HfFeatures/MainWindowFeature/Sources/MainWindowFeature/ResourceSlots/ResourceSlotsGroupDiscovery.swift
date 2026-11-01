import SwiftUI

// MARK: - ResourceSlotsGroupDiscovery

/// Generation-scoped command allowances are independent of transient discovery eligibility.
struct ResourceSlotsGroupDiscovery {
    /// The reviewed cap on group discovery commands per generation: the initial command plus
    /// one growth-gated retry. Every retry still requires fresh extent growth after its own
    /// preceding consumption, so the walk terminates on monotone convergence and stays inside
    /// the reading state's frame budget.
    static let maximumGroupDiscoveryCommands = 2

    struct Issue {
        let trigger: String
        let baseline: CGFloat?
        let contentHeight: CGFloat?
    }

    private(set) var attempts: [ResourceSlotsScrollTarget: Int] = [:]
    private(set) var settledFrames = 0
    private(set) var lastIssue: Issue?
    private var consumedTarget: ResourceSlotsScrollTarget?
    private var consumedExtent: CGFloat?
    private var settledGeometry: ResourceSlotsScrollGeometry?

    var totalAttempts: Int { attempts.values.reduce(0, +) }

    mutating func endGeneration() { self = Self() }

    mutating func invalidateEligibility() {
        consumedTarget = nil
        consumedExtent = nil
        resetSettling()
    }

    mutating func resetSettling() { settledGeometry = nil; settledFrames = 0 }

    mutating func recordInitialIssue(target: ResourceSlotsScrollTarget, geometry: ResourceSlotsScrollGeometry?) {
        attempts[target, default: 0] += 1
        invalidateEligibility()
        lastIssue = Issue(trigger: "initial", baseline: nil, contentHeight: geometry?.contentHeight)
    }

    mutating func recordConsumption(target: ResourceSlotsScrollTarget, geometry: ResourceSlotsScrollGeometry?) {
        resetSettling()
        // Every consumed group command records a fresh baseline: a retry must observe growth
        // that happened after the preceding command actually executed, never growth the
        // earlier command already saw before it was consumed.
        guard case .group = target else { return }
        consumedTarget = target
        consumedExtent = geometry?.contentHeight
    }

    mutating func qualifiesForRetry(target: ResourceSlotsScrollTarget, geometry: ResourceSlotsScrollGeometry,
                                    targetIsMissing: Bool, hasPendingCommand: Bool) -> Bool {
        guard case .group = target, (attempts[target] ?? 0) < Self.maximumGroupDiscoveryCommands, consumedTarget == target,
              let consumedExtent, geometry.contentHeight > consumedExtent + 1,
              geometry.viewportHeight > 0, targetIsMissing, !hasPendingCommand else {
            resetSettling()
            return false
        }
        if settledGeometry == geometry { settledFrames += 1 } else { settledGeometry = geometry; settledFrames = 1 }
        return settledFrames >= 2
    }

    mutating func recordRetry(target: ResourceSlotsScrollTarget, geometry: ResourceSlotsScrollGeometry) {
        let baseline = consumedExtent
        attempts[target, default: 0] += 1
        invalidateEligibility()
        lastIssue = Issue(trigger: "extent-growth", baseline: baseline, contentHeight: geometry.contentHeight)
    }
}
