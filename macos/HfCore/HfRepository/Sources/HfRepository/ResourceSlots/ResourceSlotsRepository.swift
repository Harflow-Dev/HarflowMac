import Combine
import Foundation
import Mockable
import MonitorCore
import SwiftEnvironment

// MARK: - ResourceSlotsRepository

/// Visibility-scoped resource observations. Acquiring the first lease starts work; releasing the last stops it.
@Mockable
public protocol ResourceSlotsRepository: Sendable {
    var snapshot: ResourceSlotsSnapshot { get }
    func snapshotPublisher() -> AnyPublisher<ResourceSlotsSnapshot, Never>
    func acquireObservation() async -> UUID
    func releaseObservation(_ lease: UUID) async
    /// Coalesces with an active pass and requests one follow-up pass.
    func refresh() async
    /// Revalidates selected-runtime identity when readiness or configuration changes are observed.
    func runtimeChanged() async
}

/// Complete rendering state. Poll timestamps are excluded because they do not change displayed evidence.
public struct ResourceSlotsSnapshot: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case loading, ready, notEnabled, unsupported, unavailable }
    public var phase: Phase
    public var data: ResourceSlotsData?
    public var error: ToolError?
    public var isRefreshing: Bool
    public var isStale: Bool

    public init(phase: Phase = .loading, data: ResourceSlotsData? = nil, error: ToolError? = nil,
                isRefreshing: Bool = false, isStale: Bool = false) {
        self.phase = phase
        self.data = data
        self.error = error
        self.isRefreshing = isRefreshing
        self.isStale = isStale
    }
}

/// A qualified action requires metadata from the same selected runtime.
public struct ResourceSlotOwnerMetadata: Equatable, Sendable {
    public enum Destination: Equatable, Sendable {
        case task(String)
        /// Activation context remains identity evidence; this action opens the verified run.
        case workflowRun(runID: String, activationID: String?)
    }

    public let owner: ResourceSlotOwner
    public let title: String?
    public let destination: Destination?

    public init(owner: ResourceSlotOwner, title: String?, destination: Destination?) {
        self.owner = owner
        self.title = title
        self.destination = destination
    }
}

/// Conservative join: inventory owns occupancy and FIFO order, phase status owns phase details.
public struct ResourceSlotsRow: Equatable, Sendable {
    public let reservation: ResourceReservation
    public let phase: PhaseSlotLease?
    public let phaseDetailUnavailable: Bool

    public init(reservation: ResourceReservation, phase: PhaseSlotLease?, phaseDetailUnavailable: Bool) {
        self.reservation = reservation
        self.phase = phase
        self.phaseDetailUnavailable = phaseDetailUnavailable
    }
}

/// One stable resource identity with independently qualified capacity observations.
public struct ResourceSlotsResource: Equatable, Sendable {
    public let name: String
    public let inventoryCapacity: Int?
    public let configuredCapacity: Int?
    public let holders: [ResourceSlotsRow]
    public let queue: [ResourceSlotsRow]

    /// Configured-only names are idle in the qualified complete inventory observation.
    public var isConfiguredIdle: Bool { inventoryCapacity == nil && configuredCapacity != nil }
    public var observedConsumingHolders: Int { holders.filter(\.reservation.consumesCapacity).count }
    /// Capacity disagreement between reads remains visible instead of pretending they were atomic.
    public var capacityObservationsDisagree: Bool {
        guard let inventoryCapacity, let configuredCapacity else { return false }
        return inventoryCapacity != configuredCapacity
    }

    public init(name: String, inventoryCapacity: Int?, configuredCapacity: Int?, holders: [ResourceSlotsRow], queue: [ResourceSlotsRow]) {
        self.name = name
        self.inventoryCapacity = inventoryCapacity
        self.configuredCapacity = configuredCapacity
        self.holders = holders
        self.queue = queue
    }
}

/// Successful paired observations; phase receipts never create inventory rows or occupancy.
public struct ResourceSlotsData: Equatable, Sendable {
    public let resources: [ResourceSlotsResource]
    public let phaseStatus: PhaseSlotsStatus
    public let owners: [ResourceSlotOwner: ResourceSlotOwnerMetadata]

    public init(inventory: [ResourceInventoryEntry], phaseStatus: PhaseSlotsStatus,
                owners: [ResourceSlotOwner: ResourceSlotOwnerMetadata]) {
        let inventoryByName = Dictionary(uniqueKeysWithValues: inventory.map { ($0.name, $0) })
        let leases = Dictionary(uniqueKeysWithValues: phaseStatus.leases.map { ($0.leaseID, $0) })
        let names = Set(inventoryByName.keys).union(phaseStatus.configuredCapacities.keys).sorted()
        self.resources = names.map { name in
            let observed = inventoryByName[name]
            func joined(_ row: ResourceReservation, queued: Bool, index: Int) -> ResourceSlotsRow {
                let candidate = leases[row.reservationID]
                let qualified = row.purpose == "phase" && row.leaseID == row.reservationID
                    && candidate?.name == name && candidate?.taskID == row.owner.taskID
                    && candidate?.isKnownState == true && candidate?.state == row.phaseState
                    && (queued ? candidate?.state == "queued" && candidate?.position == index + 1 : candidate?.position == nil)
                    && candidate?.capacity == observed?.capacity
                return ResourceSlotsRow(reservation: row, phase: qualified ? candidate : nil,
                                        phaseDetailUnavailable: row.purpose == "phase" && !qualified)
            }
            return ResourceSlotsResource(name: name, inventoryCapacity: observed?.capacity,
                                         configuredCapacity: phaseStatus.configuredCapacities[name],
                                         holders: (observed?.holders ?? []).enumerated().map { joined($0.element, queued: false, index: $0.offset) },
                                         queue: (observed?.queue ?? []).enumerated().map { joined($0.element, queued: true, index: $0.offset) })
        }
        self.phaseStatus = phaseStatus
        self.owners = owners
    }
}

/// Safe unconfigured dependency; it does not publish an authoritative empty inventory.
public struct NullResourceSlotsRepository: ResourceSlotsRepository {
    public init() {}
    public var snapshot: ResourceSlotsSnapshot { ResourceSlotsSnapshot(phase: .unavailable) }
    public func snapshotPublisher() -> AnyPublisher<ResourceSlotsSnapshot, Never> { Just(snapshot).eraseToAnyPublisher() }
    public func acquireObservation() async -> UUID { UUID() }
    public func releaseObservation(_: UUID) async {}
    public func refresh() async {}
    public func runtimeChanged() async {}
}

public extension GlobalValues {
    /// Shared visibility-scoped resource slot observations.
    @GlobalEntry var resourceSlotsRepository: any ResourceSlotsRepository = NullResourceSlotsRepository()
}
