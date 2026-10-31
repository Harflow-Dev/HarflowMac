import Foundation
@testable import MonitorCore
import Testing

@Suite(.serialized)
struct ResourceSlotsClientTests {
    private func fixture(_ name: String) throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ContractsV1"))
        return try #require(JSONValue.parse(Data(contentsOf: url))?.objectValue)
    }

    private func ctlRunner(
        capabilities: [String], answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput
    ) -> RecordingRunner {
        RecordingRunner { call in
            guard call.arguments == ["version-info", "--json"] else { return answer(call) }
            let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
            let encoded = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
            let document = [
                "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1,",
                "\"product_version\":\"\(HarflowVersion.current)\",\"component\":\"engine\",\"state_root\":\"\(root)\",",
                "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1},",
                "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},",
                "\"events\":{\"format\":\"harflow.event\",\"v\":1}},",
                "\"capabilities\":[\(encoded)],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
            ].joined()
            return ProcessOutput(exitCode: 0, stdout: json(document), stderr: "")
        }
    }

    @Test func givenCapabilityIsAbsent_whenEitherAggregateReadRuns_thenNoResourceCommandLaunches() async {
        // given
        let runner = ctlRunner(capabilities: ["ctl.v1", "setup.v1", "events.v1"]) { _ in
            Issue.record("A resource command must not launch without phase-slots.v1")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)

        // when
        let inventory = await client.resourceInventory()
        let phase = await client.phaseSlotsStatus()

        // then
        guard case .failure(.unsupportedCommand) = inventory else {
            Issue.record("Missing resource capability should be unsupported")
            return
        }
        guard case .failure(.unsupportedCommand) = phase else {
            Issue.record("Missing phase capability should be unsupported")
            return
        }
        #expect(runner.calls.isEmpty)
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"], ["version-info", "--json"]])
    }

    @Test func givenQualifiedRuntime_whenReadingStatus_thenNestedCommandRemainsSeparateArgvTokens() async throws {
        // given
        let runner = ctlRunner(capabilities: ["ctl.v1", "setup.v1", "events.v1", "phase-slots.v1"]) { call in
            if call.arguments == ["resources", "--json"] {
                return ProcessOutput(exitCode: 0, stdout: ctlJSON(#"{"resources":[]}"#), stderr: "")
            }
            if call.arguments == ["slot", "status", "--json"] {
                let payload = [
                    "{\"result\":{\"leases\":[],\"truncated\":false,",
                    "\"configuration\":{\"epoch\":0,\"names\":{}},",
                    "\"service\":{\"state\":\"missing\"}}}"
                ].joined()
                return ProcessOutput(exitCode: 0, stdout: ctlJSON(payload), stderr: "")
            }
            Issue.record("Unexpected aggregate argv: \(call.arguments)")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)

        // when
        _ = try await client.resourceInventory().get()
        _ = try await client.phaseSlotsStatus().get()

        // then
        #expect(runner.calls.map(\.arguments) == [["resources", "--json"], ["slot", "status", "--json"]])
    }

    @Test func givenOlderCtlRejectsNestedStatus_whenReading_thenFailureIsUnsupportedCommand() async {
        // given
        let runner = ctlRunner(capabilities: ["ctl.v1", "setup.v1", "events.v1", "phase-slots.v1"]) { _ in
            ProcessOutput(exitCode: 2, stdout: Data(), stderr: "invalid choice: 'slot'")
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)

        // when
        let result = await client.phaseSlotsStatus()

        // then
        guard case .failure(.unsupportedCommand(let tool, let command, _)) = result else {
            Issue.record("Older nested command should be unsupported")
            return
        }
        #expect(tool == "harflow-ctl")
        #expect(command == "slot status")
        #expect(runner.calls.map(\.arguments) == [["slot", "status", "--json"]])
    }

    @Test func givenCanonicalAggregateFixtures_whenDecoded_thenInventoryAndPhaseEvidenceRemainIndependent() throws {
        // given
        let inventoryEnvelope = try fixture("ctl-resources-mixed.json")
        let inventoryRaw = try #require(inventoryEnvelope["resources"]?.arrayValue)
        let inventory = try inventoryRaw.map { try ResourceInventoryEntry(raw: #require($0.objectValue)) }
        let phaseEnvelope = try fixture("ctl-phase-slot-status-populated.json")
        let phase = try PhaseSlotsStatus(raw: #require(phaseEnvelope["result"]?.objectValue))

        // when
        // then — parse each public read independently; joining belongs to the repository layer.
        let build = try #require(inventory.first { $0.name == "build" })
        #expect(build.capacity == 2)
        #expect(build.holders.first { $0.reservationID == "workflow-borrower" }?.consumesCapacity == false)
        #expect(build.holders.first { $0.reservationID == "workflow-holder" }?.releaseRequested == true)
        #expect(build.queue.map(\.reservationID) == ["build-waiter-1", "build-waiter-2"])
        let queueLeases = phase.leases
.filter { $0.state == "queued" && $0.name == "build" }
            .sorted { ($0.position ?? 0) < ($1.position ?? 0) }
        #expect(queueLeases.map(\.leaseID) == ["build-waiter-1", "build-waiter-2"])
        #expect(queueLeases.map(\.position) == [1, 2])
        #expect(phase.leases.first { $0.leaseID == "simulator-cleanup" }?.state == "cleanup_uncertain")
        #expect(phase.leases.first { $0.leaseID == "simulator-waiter" }?.blockedBy == ["simulator-cleanup"])
        #expect(inventory.first { $0.name == "unconfigured-device" }?.capacity == 1)
    }

    @Test func givenConfiguredIdleAndTruncatedFixtures_whenDecoded_thenConfiguredCapacityAndBoundsRemainExplicit() throws {
        // given
        let idleEnvelope = try fixture("ctl-phase-slot-status-configured-idle.json")
        let idleStatus = try PhaseSlotsStatus(raw: #require(idleEnvelope["result"]?.objectValue))
        let truncatedEnvelope = try fixture("ctl-phase-slot-status-truncated.json")

        // when
        let truncated = try PhaseSlotsStatus(raw: #require(try fixture("ctl-phase-slot-status-truncated.json")["result"]?.objectValue))

        // then
        #expect(idleStatus.configuredCapacities == ["build": 2, "simulator": 1])
        #expect(truncated.truncated)
        #expect(truncated.leases.count == 256)
        #expect(truncatedEnvelope["result"]?.objectValue?["truncated"]?.boolValue == true)
    }

    @Test func givenMalformedFractionsBooleansAndIdentities_whenDecoded_thenWireEvidenceIsRejected() throws {
        // given
        let envelope = try fixture("ctl-phase-slot-status-populated.json")
        var status = try #require(envelope["result"]?.objectValue)
        var leases = try #require(status["leases"]?.arrayValue)
        let first = try #require(leases.first?.objectValue)

        // when / then — integer fields do not coerce fractions, and boolean fields do not accept numbers.
        var fractional = first
        fractional["capacity"] = .number(1.5)
        #expect(throws: ToolError.self) { try PhaseSlotLease(raw: fractional) }
        var nonBoolean = first
        nonBoolean["overcommitted"] = .number(1)
        #expect(throws: ToolError.self) { try PhaseSlotLease(raw: nonBoolean) }
        var overcommitted = first
        overcommitted["overcommitted"] = .bool(true)
        #expect(try PhaseSlotLease(raw: overcommitted).overcommitted == true)
        var badIdentity = first
        badIdentity["lease_id"] = .string("../outside")
        #expect(throws: ToolError.self) { try PhaseSlotLease(raw: badIdentity) }

        var badEnvelope = status
        status["truncated"] = .number(0.5)
        #expect(throws: ToolError.self) { try PhaseSlotsStatus(raw: status) }
        badEnvelope["leases"] = .array(Array(repeating: .object(first), count: 257))
        #expect(throws: ToolError.self) { try PhaseSlotsStatus(raw: badEnvelope) }
    }

    @Test func givenUnknownOwnerAndExplicitMinimalUnavailableTaskRow_whenDecoded_thenIdentityIsRetainedWithoutInventedLease() throws {
        // given
        let owner = try ResourceSlotOwner(raw: ["kind": .string("future-owner"), "workflow_run_id": .string("run-17")])

        // when
        let context = TaskPhaseSlotsContext.decode(taskID: "task-current", raw: [
            "phase_slots": .array([.object(["task_id": .string("task-current"), "state": .string("unavailable"),
                                            "diagnostic": .string("Older runtime has no qualified phase detail.")])])
        ])

        // then
        #expect(owner.isKnown == false)
        #expect(owner.workflowRunID == "run-17")
        #expect(owner.taskID == nil)
        #expect(context == .unavailable(taskID: "task-current", diagnostic: "Older runtime has no qualified phase detail."))
        #expect(TaskPhaseSlotsContext.decode(taskID: "task-current", raw: [:]) == .hidden)
        #expect(TaskPhaseSlotsContext.decode(taskID: "task-current", raw: ["phase_slots": .array([])]) == .hidden)
    }

    @Test func givenRepairStandInTaskOwnerWithoutAssociation_whenInventoryDecodes_thenReservationIsPreservedWithoutRouteIdentity() throws {
        // given — repair may retain an owner kind while its associated task id is absent.
        let raw: [String: JSONValue] = [
            "reservation_id": .string("repair-row"), "names": .array([.string("sim")]), "state": .string("held"),
            "owner": .object(["kind": .string("task")]), "generation": .number(1),
            "enqueued_at": .string("2026-10-31T00:00:00+00:00"), "granted_at": .string("2026-10-31T00:00:01+00:00")
        ]

        // when
        let reservation = try ResourceReservation(raw: raw, held: true)

        // then — inventory remains visible; the missing association cannot become a task route.
        #expect(reservation.reservationID == "repair-row")
        #expect(reservation.owner.kind == "task")
        #expect(reservation.owner.taskID == nil)
        #expect(reservation.owner.isKnown)
    }

    @Test func givenOneHundredBlockerIDs_whenDecoded_thenDetailsStayUnavailableAndMayBeIncomplete() throws {
        // given
        let envelope = try fixture("ctl-phase-slot-status-populated.json")
        var status = try #require(envelope["result"]?.objectValue)
        var leases = try #require(status["leases"]?.arrayValue)
        let queuedIndex = try #require(leases.firstIndex { $0.objectValue?["lease_id"]?.stringValue == "build-waiter-1" })
        var queued = try #require(leases[queuedIndex].objectValue)
        let ids = (0 ..< 100).map { "blocker-\($0)" }
        queued["blocked_by"] = .array(ids.map(JSONValue.string))
        queued["blockers"] = .null
        leases[queuedIndex] = .object(queued)
        status["leases"] = .array(leases)

        // when
        let decoded = try PhaseSlotsStatus(raw: status)
        let lease = try #require(decoded.leases.first { $0.leaseID == "build-waiter-1" })

        // then
        #expect(lease.blockers == nil)
        #expect(lease.blockerDetailsAvailable == false)
        #expect(lease.blockersMayBeIncomplete)
        #expect(lease.blockedBy == ids)
    }
}
