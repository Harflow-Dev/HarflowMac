import Foundation
import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite
struct ResourceSlotsPresentationTests {
    private func owner(_ raw: [String: JSONValue]) throws -> ResourceSlotOwner { try ResourceSlotOwner(raw: raw) }

    private func data() throws -> ResourceSlotsData {
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

    @Test func givenQualifiedAndUnknownOwners_whenAssembled_thenTitlesFallBackAndOnlyQualifiedDestinationsRemainActionable() throws {
        // given
        let snapshot = ResourceSlotsSnapshot(phase: .ready, data: try data())

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
        #expect(cleanup.detail?.contains("Phase observation reports overcommit") == true)
        #expect(sim.capacitySummary.contains("observed holdings exceed capacity"))
        #expect(orphan.title == "Task identity unavailable")
        #expect(orphan.action == nil)
        #expect(result.actions[orphan.id] == nil)
        #expect(orphan.detail?.contains("Borrowed") == false)
        #expect(workflow.detail?.contains("Borrowed; no additional capacity consumed") == true)
        #expect(workflow.detail?.contains("Release requested; reservation remains retained") == true)
        #expect(result.presentation.qualifiers.contains { $0.id == "service" && $0.isWarning })
        #expect(groups.first { $0.id == "idle" }?.capacitySummary.contains("no reservations") == true)
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
