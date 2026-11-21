import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite
struct ResourceSlotsPresentationTests {
    private func owner(_ raw: [String: JSONValue]) throws -> ResourceSlotOwner { try ResourceSlotOwner(raw: raw) }

    func fixtureData() throws -> ResourceSlotsData {
        let taskOwner = try owner(["kind": .string("task"), "task_id": .string("task-1")])
        let workflowOwner = try owner(["kind": .string("workflow_attempt"), "workflow_run_id": .string("run-1"), "activation_id": .string("attempt-2")])
        let cleanupOwner = try owner(["kind": .string("task"), "task_id": .string("task-cleanup")])
        let orphanOwner = try owner(["kind": .string("task")])
        let holderRows: [(String, ResourceSlotOwner, String?, Bool, String?)] = [
            ("task-hold", taskOwner, nil, false, nil),
            ("workflow-hold", workflowOwner, "workflow-root", true, nil),
            ("cleanup-row", cleanupOwner, nil, false, "cleanup_uncertain"),
            ("unknown-owner", orphanOwner, nil, false, nil)
        ]
        let inventory = try ResourceInventoryEntry(raw: [
            "name": .string("sim"), "capacity": .number(1),
            "holders": .array(holderRows.map { id, holderOwner, borrowedFrom, releaseRequested, phaseState in
                var row: [String: JSONValue] = [
                    "reservation_id": .string(id),
                    "names": .array([.string("sim")]), "state": .string("held"),
                    "owner": .object(holderOwner.rawValue),
                    "generation": .number(1), "enqueued_at": .string("2026-10-31T00:00:00+00:00"),
                    "granted_at": .string("2026-10-31T00:00:01+00:00")
                ]
                if let borrowedFrom { row["borrows_from"] = .string(borrowedFrom) }
                if releaseRequested { row["release_requested"] = .bool(true) }
                if let phaseState {
                    row["purpose"] = .string("phase")
                    row["phase_state"] = .string(phaseState)
                    row["lease_id"] = .string(id)
                }
                return .object(row)
            }), "queue": .array([])
        ])
        let phaseStatus = try PhaseSlotsStatus(raw: [
            "leases": .array([.object([
                "lease_id": .string("cleanup-row"), "task_id": .string("task-cleanup"), "name": .string("sim"),
                "state": .string("cleanup_uncertain"), "capacity": .number(1), "position": .null,
                "overcommitted": .bool(true), "enqueued_at": .string("2026-10-31T00:00:00+00:00"),
                "granted_at": .string("2026-10-31T00:00:01+00:00"),
                "blocked_by": .array([]), "blockers": .array([])
            ])]), "truncated": .bool(false),
            "configuration": .object([
                "epoch": .number(1),
                "names": .object([
                    "sim": .object(["capacity": .number(1)]),
                    "idle": .object(["capacity": .number(2)])
                ])
            ]),
            "service": .object(["state": .string("unknown")])
        ])
        let owners = [
            taskOwner: ResourceSlotOwnerMetadata(owner: taskOwner, title: "Build turn", destination: .task("task-1")),
            workflowOwner: ResourceSlotOwnerMetadata(
                owner: workflowOwner, title: "Deployment",
                destination: .workflowRun(runID: "run-1", activationID: "attempt-2")
            ),
            cleanupOwner: ResourceSlotOwnerMetadata(owner: cleanupOwner, title: nil, destination: nil),
            orphanOwner: ResourceSlotOwnerMetadata(owner: orphanOwner, title: nil, destination: nil)
        ]
        return ResourceSlotsData(inventory: [inventory], phaseStatus: phaseStatus, owners: owners)
    }

    private func emptyData() throws -> ResourceSlotsData {
        let phaseStatus = try PhaseSlotsStatus(raw: [
            "leases": .array([]), "truncated": .bool(false),
            "configuration": .object(["epoch": .number(1), "names": .object([:])]),
            "service": .object(["state": .string("alive")])
        ])
        return ResourceSlotsData(inventory: [], phaseStatus: phaseStatus, owners: [:])
    }

    @Test func givenQualifiedAndUnknownOwners_whenAssembled_thenTitlesFallBackAndOnlyQualifiedDestinationsRemainActionable() throws {
        // given
        let snapshot = ResourceSlotsSnapshot(phase: .ready, data: try fixtureData())

        // when
        let result = ResourceSlotsAssembly.assemble(snapshot)

        // then
        guard case .ready(_, let groups) = result.presentation.state else {
            Issue.record("Expected configured and active resource groups")
            return
        }
        let sim = try #require(groups.first { $0.id == "sim" })
        let task = try #require(sim.holders.first { $0.id == "sim/task-hold" })
        let workflow = try #require(sim.holders.first { $0.id == "sim/workflow-hold" })
        let cleanup = try #require(sim.holders.first { $0.id == "sim/cleanup-row" })
        let orphan = try #require(sim.holders.first { $0.id == "sim/unknown-owner" })
        #expect(task.title == "Build turn")
        #expect(task.action == .init(label: "Open task", ownerID: "task-1"))
        #expect(result.actions[task.id] == .task("task-1"))
        #expect(workflow.title == "Deployment")
        #expect(workflow.action == .init(label: "Open workflow run", ownerID: "run-1 / attempt-2"))
        #expect(result.actions[workflow.id] == .workflowRun(runID: "run-1", activationID: "attempt-2"))
        #expect(cleanup.status == "Cleanup uncertain · capacity retained")
        #expect(cleanup.detail?.contains("Phase capacity is overcommitted") == true)
        #expect(sim.capacitySummary.contains("above capacity"))
        #expect(orphan.title == "Reservation unknown-owner")
        #expect(orphan.action == nil)
        #expect(result.actions[orphan.id] == nil)
        #expect(orphan.detail?.contains("Borrowed") == false)
        #expect(workflow.detail?.contains("Borrowed; no extra capacity") == true)
        #expect(workflow.detail?.contains("Release requested; capacity retained") == true)
        #expect(result.presentation.qualifiers.contains { $0.id == "service" && $0.isWarning })
        let idle = try #require(groups.first { $0.id == "idle" })
        #expect(idle.capacitySummary == "0 of 2 in use")
        #expect(idle.emptyHolderMessage == "No current holders.")
    }

    @Test func givenOverCapacityWithBorrowedCleanupAndWaiter_whenAssembled_thenMeterCountsOnlyConsumingHoldersAndQueue() throws {
        // given
        let snapshot = try overCapacitySnapshot(
            inventoryCapacity: 2,
            configuredCapacity: 2,
            consumingHolders: 3,
            borrowedHolders: 1,
            queueCount: 1,
            cleanupHolderID: "holder-2"
        )

        // when
        let result = ResourceSlotsAssembly.assemble(snapshot)

        // then
        guard case .ready(_, let groups) = result.presentation.state,
              let group = groups.first(where: { $0.id == "sim" }) else {
            Issue.record("Expected a resource group for the qualified inventory")
            return
        }
        #expect(group.capacitySummary == "3 of 2 in use · above capacity · 1 borrowed")
        #expect(group.meterCells == [.used, .used, .aboveCapacity, .waiting])
        #expect(group.holders.count == 4)
        #expect(group.holders.first(where: { $0.id == "sim/holder-2" })?.detail?.contains("Phase capacity is overcommitted") == true)
        #expect(group.waiters.count == 1)
    }

    @Test func givenInventoryOnlyCapacity_whenOverCapacity_thenMeterStillUsesQualifiedInventory() throws {
        // given
        let snapshot = try overCapacitySnapshot(
            inventoryCapacity: 2,
            configuredCapacity: nil,
            consumingHolders: 3,
            borrowedHolders: 0,
            queueCount: 0
        )

        // when
        let result = ResourceSlotsAssembly.assemble(snapshot)

        // then
        guard case .ready(_, let groups) = result.presentation.state else {
            Issue.record("Expected ready resource observations")
            return
        }
        #expect(groups.first?.meterCells == [.used, .used, .aboveCapacity])
    }

    @Test func givenCapacityConflictOrOrdinaryUsage_whenAssembled_thenMeterFallsBackToExistingText() throws {
        // given
        let conflict = try overCapacitySnapshot(
            inventoryCapacity: 2,
            configuredCapacity: 3,
            consumingHolders: 3,
            borrowedHolders: 0,
            queueCount: 0
        )
        let ordinary = try overCapacitySnapshot(
            inventoryCapacity: 3,
            configuredCapacity: 3,
            consumingHolders: 2,
            borrowedHolders: 0,
            queueCount: 1
        )
        let configuredOnly = try overCapacitySnapshot(
            inventoryCapacity: 2,
            configuredCapacity: 2,
            consumingHolders: 0,
            borrowedHolders: 0,
            queueCount: 0,
            includeInventory: false
        )

        // when
        let conflictResult = ResourceSlotsAssembly.assemble(conflict)
        let ordinaryResult = ResourceSlotsAssembly.assemble(ordinary)
        let configuredOnlyResult = ResourceSlotsAssembly.assemble(configuredOnly)

        // then
        guard case .ready(_, let conflictGroups) = conflictResult.presentation.state,
              case .ready(_, let ordinaryGroups) = ordinaryResult.presentation.state,
              case .ready(_, let configuredOnlyGroups) = configuredOnlyResult.presentation.state else {
            Issue.record("Expected ready resource observations")
            return
        }
        #expect(conflictGroups.first?.capacitySummary.contains("capacity differs between reads") == true)
        #expect(conflictGroups.first?.meterCells == nil)
        #expect(ordinaryGroups.first?.meterCells == nil)
        #expect(configuredOnlyGroups.first?.meterCells == nil)
        #expect(configuredOnlyGroups.first?.capacitySummary == "0 of 2 in use")
    }

    @Test func givenCellCountAtAndBeyondBound_whenAssembled_thenOnlyTwelveCellMeterIsRetained() throws {
        // given
        let atBound = try overCapacitySnapshot(
            inventoryCapacity: 6,
            configuredCapacity: 6,
            consumingHolders: 7,
            borrowedHolders: 0,
            queueCount: 5
        )
        let beyondBound = try overCapacitySnapshot(
            inventoryCapacity: 6,
            configuredCapacity: 6,
            consumingHolders: 7,
            borrowedHolders: 0,
            queueCount: 6
        )

        // when
        let atBoundResult = ResourceSlotsAssembly.assemble(atBound)
        let beyondBoundResult = ResourceSlotsAssembly.assemble(beyondBound)

        // then
        guard case .ready(_, let atBoundGroups) = atBoundResult.presentation.state,
              case .ready(_, let beyondBoundGroups) = beyondBoundResult.presentation.state else {
            Issue.record("Expected ready resource observations")
            return
        }
        #expect(atBoundGroups.first?.meterCells?.count == 12)
        #expect(beyondBoundGroups.first?.meterCells == nil)
        #expect(beyondBoundGroups.first?.capacitySummary == "7 of 6 in use · above capacity")
    }

    private func overCapacitySnapshot(
        inventoryCapacity: Int,
        configuredCapacity: Int?,
        consumingHolders: Int,
        borrowedHolders: Int,
        queueCount: Int,
        cleanupHolderID: String? = nil,
        includeInventory: Bool = true
    ) throws -> ResourceSlotsSnapshot {
        let holders = (0 ..< consumingHolders + borrowedHolders).map { index -> [String: JSONValue] in
            let id = "holder-\(index)"
            var row: [String: JSONValue] = [
                "reservation_id": .string(id), "names": .array([.string("sim")]), "state": .string("held"),
                "owner": .object(["kind": .string("task"), "task_id": .string("task-\(index)")]),
                "generation": .number(1), "enqueued_at": .string("2026-10-31T00:00:00+00:00"),
                "granted_at": .string("2026-10-31T00:00:01+00:00")
            ]
            if index >= consumingHolders { row["borrows_from"] = .string("holder-0") }
            if id == cleanupHolderID {
                row["purpose"] = .string("phase")
                row["phase_state"] = .string("cleanup_uncertain")
                row["lease_id"] = .string(id)
            }
            return row
        }
        let waiters = (0 ..< queueCount).map { index in
            JSONValue.object([
                "reservation_id": .string("waiter-\(index)"), "names": .array([.string("sim")]),
                "owner": .object(["kind": .string("task"), "task_id": .string("waiting-\(index)")]),
                "generation": .number(1), "enqueued_at": .string("2026-10-31T00:00:02+00:00")
            ])
        }
        let inventory = try ResourceInventoryEntry(raw: [
            "name": .string("sim"), "capacity": .number(Double(inventoryCapacity)),
            "holders": .array(holders.map(JSONValue.object)), "queue": .array(waiters)
        ])
        let leases: [JSONValue] = cleanupHolderID.map { id in
            [.object([
                "lease_id": .string(id), "task_id": .string("task-2"), "name": .string("sim"),
                "state": .string("cleanup_uncertain"), "capacity": .number(Double(inventoryCapacity)), "position": .null,
                "overcommitted": .bool(true), "enqueued_at": .string("2026-10-31T00:00:00+00:00"),
                "granted_at": .string("2026-10-31T00:00:01+00:00"), "blocked_by": .array([]), "blockers": .array([])
            ])]
        } ?? []
        var names: [String: JSONValue] = [:]
        if let configuredCapacity {
            names["sim"] = .object(["capacity": .number(Double(configuredCapacity))])
        }
        let phaseStatus = try PhaseSlotsStatus(raw: [
            "leases": .array(leases), "truncated": .bool(false),
            "configuration": .object(["epoch": .number(1), "names": .object(names)]),
            "service": .object(["state": .string("alive")])
        ])
        let data = ResourceSlotsData(inventory: includeInventory ? [inventory] : [], phaseStatus: phaseStatus, owners: [:])
        return ResourceSlotsSnapshot(phase: .ready, data: data)
    }

    @Test func givenStaleSnapshot_whenAssembled_thenOnlyStaleQualifierOffersRetryIncludingRetainedEmpty() throws {
        // given
        let retainedData = try fixtureData()
        let stalePopulated = ResourceSlotsAssembly.assemble(ResourceSlotsSnapshot(phase: .ready, data: retainedData, isStale: true)).presentation
        let emptySnapshot = ResourceSlotsSnapshot(phase: .ready, data: try emptyData())
        let staleEmptySnapshot = ResourceSlotsSnapshot(phase: .ready, data: try emptyData(), isStale: true)
        let staleEmpty = ResourceSlotsAssembly.assemble(staleEmptySnapshot).presentation
        let ordinaryEmpty = ResourceSlotsAssembly.assemble(emptySnapshot).presentation
        let unsupported = ResourceSlotsAssembly.assemble(ResourceSlotsSnapshot(phase: .unsupported)).presentation
        let unavailable = ResourceSlotsAssembly.assemble(ResourceSlotsSnapshot(phase: .unavailable)).presentation
        let retainedUnsupported = ResourceSlotsAssembly.assemble(
            ResourceSlotsSnapshot(phase: .unsupported, data: retainedData, isStale: true)
        )
.presentation
        let retainedNotEnabled = ResourceSlotsAssembly.assemble(
            ResourceSlotsSnapshot(phase: .notEnabled, data: retainedData, isStale: true)
        )
.presentation

        // then
        #expect(stalePopulated.qualifiers.contains { $0.id == "stale" && $0.showsRetry })
        #expect(staleEmpty.qualifiers.contains { $0.id == "stale" && $0.showsRetry })
        #expect(ordinaryEmpty.qualifiers.allSatisfy { !$0.showsRetry })
        #expect(unsupported.qualifiers.allSatisfy { !$0.showsRetry })
        #expect(unavailable.qualifiers.allSatisfy { !$0.showsRetry })
        #expect(retainedUnsupported.qualifiers.contains { $0.id == "stale" && $0.showsRetry })
        #expect(retainedNotEnabled.qualifiers.contains { $0.id == "stale" && $0.showsRetry })
    }

    @Test func givenCurrentTaskSnapshot_whenMapped_thenAbsentEmptyUnavailableAndQueueBlockersStayDistinct() throws {
        // given
        let unavailable: [String: JSONValue] = ["phase_slots": .array([.object([
            "task_id": .string("task-current"), "state": .string("unavailable"),
            "diagnostic": .string("Older runtime does not provide phase detail.")
        ])])]
        let blockers: [JSONValue] = (0 ..< 100).map { .string("blocker-\($0)") }
        let queued: [String: JSONValue] = ["phase_slots": .array([.object([
            "lease_id": .string("lease-current"), "task_id": .string("task-current"), "name": .string("sim"),
            "state": .string("queued"), "capacity": .number(1), "position": .number(1),
            "enqueued_at": .string("2026-10-31T00:00:00+00:00"), "blocked_by": .array(blockers), "blockers": .null
        ])])]

        // when
        let absent = TaskDetailResourceContext.prepare(taskID: "task-current", raw: [:])
        let empty = TaskDetailResourceContext.prepare(taskID: "task-current", raw: ["phase_slots": .array([])])
        let unavailableContext = TaskDetailResourceContext.prepare(taskID: "task-current", raw: unavailable)
        let queueContext = TaskDetailResourceContext.prepare(taskID: "task-current", raw: queued)
        let staleMember = TaskDetailResourceContext.prepare(taskID: "task-current", raw: ["phase_slots": .array([.object([
            "task_id": .string("task-previous"), "state": .string("unavailable"), "diagnostic": .string("stale")
        ])])])

        // then
        #expect(absent == nil)
        #expect(empty == nil)
        #expect(unavailableContext?.title == "Resource context unavailable")
        #expect(queueContext?.title == "Waiting for sim")
        #expect(queueContext?.message.contains("Queue position 1") == true)
        #expect(queueContext?.blockers?.rows.count == 100)
        #expect(queueContext?.blockers?.note?.contains("Up to 100 blockers") == true)
        #expect(staleMember?.title == "Resource context unavailable")
        #expect(staleMember?.message.contains("malformed public task projection") == true)
    }
}

private extension ResourceSlotOwner {
    var rawValue: [String: JSONValue] {
        ["kind": .string(kind), "task_id": taskID.map(JSONValue.string) ?? .null,
         "workflow_run_id": workflowRunID.map(JSONValue.string) ?? .null,
         "activation_id": activationID.map(JSONValue.string) ?? .null]
    }
}
