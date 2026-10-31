import Foundation
@testable import HfRepository
import MonitorCore
import Testing

@Suite
struct ResourceSlotsDataTests {
    @Test func givenSeparateQueueReadsAreReorderedOrDisagree_whenJoined_thenInventoryFifoAndCapacityProvenanceRemain() throws {
        // given
        let owner: [String: JSONValue] = ["kind": .string("task"), "task_id": .string("task-1")]
        let inventory = try ResourceInventoryEntry(raw: [
            "name": .string("sim"), "capacity": .number(2), "holders": .array([]),
            "queue": .array((1 ... 2).map { index in
                .object([
                    "reservation_id": .string("waiter-\(index)"), "names": .array([.string("sim")]),
                    "state": .string("queued"), "owner": .object(owner), "generation": .number(1),
                    "enqueued_at": .string("2026-10-31T00:00:0\(index)+00:00"), "purpose": .string("phase"),
                    "phase_state": .string("queued"), "lease_id": .string("waiter-\(index)")
                ])
            })
        ])
        var phaseRows: [JSONValue] = (1 ... 2).map { index in
            JSONValue.object([
                "lease_id": .string("waiter-\(index)"), "task_id": .string("task-1"), "name": .string("sim"),
                "state": .string("queued"), "capacity": .number(2), "position": .number(Double(index)),
                "enqueued_at": .string("2026-10-31T00:00:0\(index)+00:00"),
                "blocked_by": .array([]), "blockers": .array([])
            ])
        }
        phaseRows.reverse()
        let configuration: JSONValue = .object(["epoch": .number(1), "names": .object(["sim": .object(["capacity": .number(4)])])])
        var statusRaw: [String: JSONValue] = [
            "leases": .array(phaseRows), "truncated": .bool(false), "configuration": configuration,
            "service": .object(["state": .string("missing")])
        ]

        // when
        let reordered = try PhaseSlotsStatus(raw: statusRaw)
        let joined = ResourceSlotsData(inventory: [inventory], phaseStatus: reordered, owners: [:])

        // then — queue order comes from inventory; matching phase identity can join despite array order.
        let resource = try #require(joined.resources.first { $0.name == "sim" })
        #expect(resource.queue.map(\.reservation.reservationID) == ["waiter-1", "waiter-2"])
        #expect(resource.queue.map { $0.phase?.position } == [1, 2])
        #expect(resource.capacityObservationsDisagree)

        // when — one of the separately observed phase positions no longer agrees with the inventory FIFO.
        if let index = phaseRows.firstIndex(where: { $0.objectValue?["lease_id"]?.stringValue == "waiter-1" }),
           var stale = phaseRows[index].objectValue {
            stale["position"] = .number(3)
            phaseRows[index] = .object(stale)
        }
        statusRaw["leases"] = .array(phaseRows)
        let stale = ResourceSlotsData(inventory: [inventory], phaseStatus: try PhaseSlotsStatus(raw: statusRaw), owners: [:])

        // then — the queue remains qualified inventory evidence while only the mismatched join is unavailable.
        let staleQueue = try #require(stale.resources.first { $0.name == "sim" }).queue
        #expect(staleQueue.map(\.reservation.reservationID) == ["waiter-1", "waiter-2"])
        #expect(staleQueue[0].phase == nil)
        #expect(staleQueue[0].phaseDetailUnavailable)
        #expect(staleQueue[1].phase?.position == 2)
    }
}
