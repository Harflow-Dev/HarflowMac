import Foundation
import HfRepository
import MonitorCore

// MARK: - ResourceSlotsAssemblyResult

struct ResourceSlotsAssemblyResult: Sendable {
    let presentation: ResourceSlotsPresentation
    let actions: [String: ResourceSlotOwnerMetadata.Destination]
    let resourceIDs: [String]
    let rowIDs: Set<String>
}

// MARK: - ResourceSlotsAssembly

/// Pure background preparation. The visual component receives complete text and qualified actions.
enum ResourceSlotsAssembly {
    static func assemble(_ snapshot: ResourceSlotsSnapshot) -> ResourceSlotsAssemblyResult {
        var qualifiers = refreshQualifiers(snapshot)
        guard let data = snapshot.data else {
            return .init(presentation: .init(state: unqualifiedState(snapshot), qualifiers: qualifiers),
                         actions: [:], resourceIDs: [], rowIDs: [])
        }
        if let service = serviceQualifier(data) { qualifiers.append(service) }
        if !data.phaseStatus.cleanupPolicyUnavailableNames.isEmpty {
            qualifiers.append(.init(id: "cleanup-policy", text: "Cleanup configuration is unavailable for some resources.", isWarning: true))
        }
        if data.phaseStatus.truncated {
            let text = "Up to 256 phase leases are shown. Additional phase details may be unavailable; "
                + "inventory occupancy is a separate observation."
            qualifiers.append(.init(id: "phase-truncated", text: text, isWarning: true))
        }
        var actions: [String: ResourceSlotOwnerMetadata.Destination] = [:]
        let groups = data.resources.map { group($0, data: data, actions: &actions) }
        let state = populatedState(data, groups: groups)
        let rowIDs = Set(groups.flatMap { ($0.holders + $0.waiters).map(\.id) })
        return .init(presentation: .init(state: state, qualifiers: qualifiers), actions: actions,
                     resourceIDs: data.resources.map(\.name), rowIDs: rowIDs)
    }

    private static func refreshQualifiers(_ snapshot: ResourceSlotsSnapshot) -> [ResourceSlotsQualifier] {
        var qualifiers: [ResourceSlotsQualifier] = []
        if snapshot.isRefreshing {
            qualifiers.append(.init(id: "refreshing", text: "Refreshing resource observations…", isWarning: false))
        }
        if snapshot.isStale {
            let text = "Showing the last successful observations. " + (snapshot.error?.message ?? "Refresh failed.")
            qualifiers.append(.init(id: "stale", text: text, isWarning: true))
        }
        return qualifiers
    }

    private static func unqualifiedState(_ snapshot: ResourceSlotsSnapshot) -> ResourceSlotsPresentation.State {
        switch snapshot.phase {
        case .loading: .loading
        case .notEnabled:
            .notEnabled(title: "Resource slots are not enabled",
                        message: snapshot.error?.message ?? "The selected runtime has not enabled phase slots.")
        case .unsupported:
            .unsupported(title: "Resource slots are unsupported",
                         message: snapshot.error?.message ?? "The selected runtime does not support phase-slots.v1.")
        case .unavailable, .ready:
            .unavailable(title: "Resource slots are unavailable",
                         message: snapshot.error?.message ?? "The engine did not provide qualified resource observations.")
        }
    }

    private static func serviceQualifier(_ data: ResourceSlotsData) -> ResourceSlotsQualifier? {
        let retainedCleanup = data.resources.contains { resource in
            resource.holders.contains { $0.reservation.phaseState?.hasPrefix("cleanup_") == true }
        }
        let policy = data.phaseStatus
        let phaseCleanup = policy.leases.contains { $0.state.hasPrefix("cleanup_") }
        guard retainedCleanup || phaseCleanup || !policy.cleanupConfiguredNames.isEmpty || !policy.cleanupPolicyUnavailableNames.isEmpty else { return nil }
        let suffix = retainedCleanup || phaseCleanup ? " Cleanup capacity remains held." : " Resources with cleanup may need attention."
        let text: String
        switch policy.service {
        case .alive: return nil
        case .dead: text = "Cleanup service is not running." + suffix
        case .missing: text = "Cleanup service has not started." + suffix
        case .stopping: text = "Cleanup service is stopping." + suffix
        case .unknown: text = "Cleanup service status is unknown." + suffix
        }
        return .init(id: "service", text: text, isWarning: true)
    }

    private static func populatedState(_ data: ResourceSlotsData, groups: [ResourceSlotsGroup]) -> ResourceSlotsPresentation.State {
        guard !groups.isEmpty else {
            return .empty(title: "No resource slots", message: "No configured names or active reservations were reported in these observations.")
        }
        let consuming = data.resources.reduce(0) { $0 + $1.observedConsumingHolders }
        let queued = data.resources.reduce(0) { $0 + $1.queue.count }
        let noun = groups.count == 1 ? "resource" : "resources"
        let summary = "\(groups.count) \(noun) · \(consuming) in use · \(queued) waiting"
        return .ready(summary: summary, groups: groups)
    }

    private static func group(
        _ resource: ResourceSlotsResource, data: ResourceSlotsData,
        actions: inout [String: ResourceSlotOwnerMetadata.Destination]
    ) -> ResourceSlotsGroup {
        let holders = resource.holders.map {
            row($0, name: resource.name, data: data, position: nil, actions: &actions)
        }
        let waiters = resource.queue.enumerated().map {
            row($0.element, name: resource.name, data: data, position: $0.offset, actions: &actions)
        }
        return .init(id: resource.name, title: resource.name, capacitySummary: capacitySummary(resource),
                     holderHeading: resource.holders.count == 1 ? "Current holder" : "Holders", holders: holders,
                     emptyHolderMessage: resource.holders.isEmpty ? "No current holders." : nil,
                     waiterHeading: resource.queue.isEmpty ? nil : "Waiting · in order", waiters: waiters)
    }

    private static func row(
        _ value: ResourceSlotsRow, name: String, data: ResourceSlotsData, position: Int?,
        actions: inout [String: ResourceSlotOwnerMetadata.Destination]
    ) -> ResourceSlotsOwner {
        let reservation = value.reservation
        let queued = position != nil
        let rowID = name + "/" + reservation.reservationID
        let owner = reservation.owner
        let associationMissing = owner.taskID == nil && owner.workflowRunID == nil && owner.activationID == nil
        let ownerID = associationMissing ? "Reservation " + reservation.reservationID : identity(owner)
        let metadata = data.owners[reservation.owner]
        var action: ResourceSlotsOwner.Action?
        if let destination = metadata?.destination {
            actions[rowID] = destination
            let label = switch destination {
            case .task: "Open task"
            case .workflowRun: "Open workflow run"
            }
            action = .init(label: label, ownerID: ownerID)
        }
        let details = reservationDetails(value)
        return .init(id: rowID, title: nonempty(metadata?.title) ?? ownerID, ownerID: ownerID,
                     status: reservation.purpose == "phase" ? stateLabel(reservation.phaseState) : (queued ? "Waiting" : "Holding"),
                     since: since(queued ? reservation.enqueuedAt : reservation.grantedAt),
                     detail: details.isEmpty ? nil : details.joined(separator: ". "), position: position.map { String($0 + 1) },
                     action: action, blockers: value.phase.flatMap { $0.state == "queued" ? blockers($0, owners: data.owners) : nil })
    }

    private static func reservationDetails(_ value: ResourceSlotsRow) -> [String] {
        let reservation = value.reservation
        var details: [String] = []
        let owner = reservation.owner
        if owner.taskID == nil, owner.workflowRunID == nil, owner.activationID == nil {
            details.append("Owner association unavailable")
        }
        if reservation.borrowsFrom != nil { details.append("Borrowed; no extra capacity") }
        if reservation.releaseRequested { details.append("Release requested; capacity retained") }
        if value.phaseDetailUnavailable { details.append("Phase details unavailable") }
        if let diagnostic = reservation.diagnostic { details.append(diagnostic) }
        if value.phase?.overcommitted == true { details.append("Phase capacity is overcommitted") }
        return details
    }

    private static func capacitySummary(_ resource: ResourceSlotsResource) -> String {
        var capacity: String
        if let inventory = resource.inventoryCapacity {
            capacity = "\(resource.observedConsumingHolders) of \(inventory) in use"
            if resource.observedConsumingHolders > inventory { capacity += " · above capacity" }
            if resource.capacityObservationsDisagree, let configured = resource.configuredCapacity {
                capacity += " · capacity differs between reads (configured: \(configured))"
            }
        } else if let configured = resource.configuredCapacity {
            capacity = "0 of \(configured) in use"
        } else {
            capacity = "Capacity unavailable"
        }
        let borrowed = resource.holders.filter { !$0.reservation.consumesCapacity }.count
        if borrowed > 0 { capacity += " · \(borrowed) borrowed" }
        return capacity
    }

    static func blockers(_ lease: PhaseSlotLease, owners: [ResourceSlotOwner: ResourceSlotOwnerMetadata] = [:]) -> ResourceSlotsBlockers {
        let rows: [ResourceSlotsBlocker] = if let details = lease.blockers {
            details.map { blocker in
                let owner = identity(blocker.owner)
                let label = nonempty(owners[blocker.owner]?.title).map { $0 + " · " + owner } ?? owner
                let suffix = since(blocker.since).map { " · " + $0 } ?? ""
                let retained = blocker.releaseRequested ? " · release requested, retained" : ""
                return .init(id: blocker.reservationID, text: "\(label) · \(stateLabel(blocker.state))\(suffix)\(retained)")
            }
        } else {
            (lease.blockedBy ?? []).map { .init(id: $0, text: $0 + " · blocker details unavailable") }
        }
        var notes: [String] = []
        if !lease.blockerDetailsAvailable {
            notes.append("Some blocker details are unavailable.")
        } else if rows.isEmpty {
            notes.append("No blockers reported.")
        }
        if lease.blockersMayBeIncomplete { notes.append("Up to 100 blockers shown; additional blockers may be unavailable.") }
        return .init(rows: rows, note: notes.isEmpty ? nil : notes.joined(separator: " "))
    }

    static func identity(_ owner: ResourceSlotOwner) -> String {
        switch owner.kind {
        case "task": owner.taskID ?? "Task identity unavailable"
        case "workflow_run": owner.workflowRunID ?? "Workflow identity unavailable"
        case "workflow_attempt": (owner.workflowRunID ?? "Workflow identity unavailable") + " / " + (owner.activationID ?? "Activation unavailable")
        default: [owner.taskID, owner.workflowRunID, owner.activationID].compactMap(\.self).first ?? "Owner unavailable (\(owner.kind))"
        }
    }

    static func stateLabel(_ value: String?) -> String {
        switch value {
        case "queued": "Waiting"
        case "held": "Holding"
        case "cleanup_pending": "Cleanup pending · capacity retained"
        case "cleanup_running": "Cleanup running · capacity retained"
        case "cleanup_failed": "Cleanup failed · capacity retained"
        case "cleanup_uncertain": "Cleanup uncertain · capacity retained"
        case "released": "Released"
        case "expired": "Expired"
        case "resolved": "Resolved"
        default: "Phase state unavailable"
        }
    }

    static func since(_ value: String?) -> String? {
        guard let value, let date = ISODate.parse(value) else { return nil }
        return "Since " + date.formatted(sinceStyle)
    }

    private static let sinceStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)

    private static func nonempty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
}
