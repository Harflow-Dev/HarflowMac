import Foundation

// MARK: - ResourceSlotsClient

public extension CtlClient {
    /// Reads current whole-task, workflow and phase reservations after a fresh capability probe.
    func resourceInventory() async -> Result<[ResourceInventoryEntry], ToolError> {
        await raw("resources", requiringCapability: "phase-slots.v1").flatMap { output in
            Self.decodeSlots(output, command: "resources", productVersion: compatibilityContext.productVersion) { raw in
                let rows = try SlotWire.array(raw, "resources", maximum: 65_536)
                try Self.validateInventoryBounds(rows)
                let entries = try rows.map { try ResourceInventoryEntry(raw: SlotWire.row($0)) }
                guard Set(entries.map(\.name)).count == entries.count else { throw SlotWire.invalid("duplicate resource names") }
                return entries
            }
        }
    }

    /// Reads the bounded phase aggregate. Inventory and phase status are separate observations.
    func phaseSlotsStatus() async -> Result<PhaseSlotsStatus, ToolError> {
        await raw(commandPath: ["slot", "status"], label: "slot status", requiringCapability: "phase-slots.v1").flatMap { output in
            Self.decodeSlots(output, command: "slot status", productVersion: compatibilityContext.productVersion) { raw in
                try PhaseSlotsStatus(raw: SlotWire.object(raw, "result"))
            }
        }
    }

    private static func validateInventoryBounds(_ resources: [JSONValue]) throws {
        var occurrences: [String: Int] = [:]
        var total = 0
        for resource in resources {
            let raw = try SlotWire.row(resource)
            let holders = try SlotWire.array(raw, "holders", maximum: 4096)
            let queue = try SlotWire.array(raw, "queue", maximum: 4096)
            guard holders.count + queue.count <= 4096 else { throw SlotWire.invalid("resource reservation bound") }
            for reservation in holders + queue {
                let id = try SlotWire.reservationIdentity(SlotWire.row(reservation), "reservation_id")
                total += 1
                occurrences[id, default: 0] += 1
                guard total <= 65_536, occurrences.count <= 4096, occurrences[id, default: 0] <= 16 else {
                    throw SlotWire.invalid("aggregate reservation bound")
                }
            }
        }
    }

    private static func decodeSlots<Value>(_ output: ProcessOutput, command: String, productVersion: String,
                                           transform: ([String: JSONValue]) throws -> Value) -> Result<Value, ToolError> {
        let start = MonitorMetrics.begin()
        defer { MonitorMetrics.end(start, stage: .decode, bytes: output.stdout.count) }
        return CtlDocument.validatedDocument(stdout: output.stdout, stderr: output.stderr, exitCode: output.exitCode,
                                             command: command, productVersion: productVersion).flatMap { validated in
            switch validated {
            case .error(let code, let message): return .failure(.refused(code: code, message: message))
            case .document(let raw):
                guard output.exitCode == 0 else { return .failure(.unreadable(tool: "harflow-ctl", exitCode: output.exitCode, stderr: output.stderr)) }
                do {
                    return .success(try transform(raw))
                } catch let error as ToolError {
                    return .failure(error)
                } catch {
                    return .failure(SlotWire.invalid("aggregate"))
                }
            }
        }
    }
}
