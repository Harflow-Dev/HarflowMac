import Foundation
@testable import MonitorCore
import Testing

// MARK: - EngineObservationFixtureTests

@Suite
struct EngineObservationFixtureTests {
    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ContractsV1"))
        return try Data(contentsOf: url)
    }

    private func status(_ name: String) throws -> TaskInfo {
        let result = CtlDocument.decode(stdout: try fixture(name), stderr: "", exitCode: 0, command: "status")
        guard case .success(.task(let task)) = result else {
            Issue.record("expected a status task in \(name)")
            throw CancellationError()
        }
        return task
    }

    private func cancelResult(_ name: String) throws -> [String: JSONValue] {
        let result = CtlDocument.decode(stdout: try fixture(name), stderr: "", exitCode: 0, command: "cancel")
        guard case .success(.result(let payload)) = result else {
            Issue.record("expected a cancel result in \(name)")
            throw CancellationError()
        }
        return payload
    }

    private func artifactPayload(_ name: String) throws -> [String: JSONValue] {
        let result = CtlDocument.decode(stdout: try fixture(name), stderr: "", exitCode: 0, command: "task-artifacts")
        guard case .success(.result(let payload)) = result else {
            Issue.record("expected an artifacts result in \(name)")
            throw CancellationError()
        }
        return payload
    }

    // MARK: Continuation stop

    private static let stopCases: [(String, ContinuationStop.State, ContinuationStop.Reason?)] = [
        ("ctl-task-status-continuation-stopped.json", .stopped, .chainCancelled),
        ("ctl-task-status-continuation-not-stopped.json", .notStopped, nil),
        ("ctl-task-status-continuation-unknown.json", .unknown, nil),
        ("ctl-task-status-brief-continuation-stopped.json", .stopped, .chainCancelled)
    ]

    @Test(arguments: stopCases)
    func givenStatusFixture_whenReadingContinuationStop_thenFiveFieldsDecode(
        _ name: String, _ state: ContinuationStop.State, _ reason: ContinuationStop.Reason?
    ) throws {
        // given
        let task = try status(name)

        // when
        let stop = try #require(task.continuationStop.value)

        // then
        #expect(stop.state == state)
        #expect(stop.reason == reason)
        #expect(stop.chainRootTaskID == "task-continuation-stop")
        #expect(stop.observedAt == "2026-10-15T00:00:00+00:00")
        if state == .stopped {
            #expect(stop.cancelledTaskID == "task-continuation-stop")
        } else {
            #expect(stop.cancelledTaskID == nil)
        }
    }

    @Test
    func givenBatchFixture_whenReadingContinuationStop_thenRowCarriesObservation() throws {
        // given
        let result = CtlDocument.decodeBatchResult(
            stdout: try fixture("ctl-task-status-batch-continuation-stop.json"), stderr: "", exitCode: 0, command: "status-batch"
        )

        // when
        let batch = try result.get()

        // then
        #expect(batch.tasks.count == 1)
        #expect(batch.tasks[0].continuationStop.value?.state == .stopped)
        #expect(batch.errors["missing-task"]?.code == "unknown_task")
    }

    @Test
    func givenOlderEngineStatus_whenReadingContinuationStop_thenItIsAbsent() throws {
        // given
        let task = try status("ctl-success.json")

        // then
        #expect(task.continuationStop == .absent)
    }

    @Test
    func givenOptedOutAndFullStatusFixtures_whenReadingContinuationStop_thenNoFixtureIsMalformed() throws {
        // given
        let names = ["ctl-success.json", "ctl-approval-status-awaiting.json"]

        // when / then
        for name in names {
            let task = try status(name)
            #expect(task.continuationStop != .malformed, "\(name)")
        }
    }

    @Test
    func givenUnknownEnumValues_whenDecoded_thenTheyAreKeptAsUnrecognized() throws {
        // given
        let raw: [String: JSONValue] = [
            "state": .string("future_state"), "chain_root_task_id": .null, "reason": .string("future_reason"),
            "cancelled_task_id": .null, "observed_at": .string("2026-10-15T00:00:00+00:00")
        ]

        // when
        let object = try #require(ContinuationStop(raw: raw))

        // then
        #expect(object.state == .unrecognized("future_state"))
        #expect(object.reason == .unrecognized("future_reason"))
        #expect(object.chainRootTaskID == nil)
    }

    @Test
    func givenDamagedObject_whenReadingContinuationStop_thenItIsMalformedNotAbsent() throws {
        // given
        let good: [String: JSONValue] = [
            "state": .string("stopped"), "chain_root_task_id": .string("r"), "reason": .string("chain_cancelled"),
            "cancelled_task_id": .null, "observed_at": .string("2026-10-15T00:00:00+00:00")
        ]
        var wrongType = good
        wrongType["state"] = .number(1)
        var missingField = good
        missingField["cancelled_task_id"] = nil
        var badRoot = good
        badRoot["chain_root_task_id"] = .number(3)

        // when / then
        #expect(ContinuationStop.reading(in: ["continuation_stop": .object(good)]).value?.state == .stopped)
        #expect(ContinuationStop.reading(in: [:]) == .absent)
        for damaged in [JSONValue.object(wrongType), .object(missingField), .object(badRoot), .null, .string("stopped"), .array([])] {
            #expect(ContinuationStop.reading(in: ["continuation_stop": damaged]) == .malformed)
        }
    }

    // MARK: chain_stopped

    @Test
    func givenRefusalShapes_whenReadingChainStopped_thenOnlyTheStartFailedShapeMatches() {
        // given
        func refusal(_ code: String, _ data: [String: JSONValue]) -> ToolError {
            .structuredRefusal(code: code, message: "ValueError: Continuation chain was cancelled; start a new task explicitly", data: data)
        }
        let shape: [String: JSONValue] = ["reason": .string("chain_stopped"), "chain_root_task_id": .string("root")]

        // then
        #expect(refusal("start_failed", shape).chainStopped?.chainRootTaskID == "root")
        #expect(refusal("other", shape).chainStopped == nil)
        #expect(refusal("start_failed", ["reason": .string("other"), "chain_root_task_id": .string("root")]).chainStopped == nil)
        #expect(refusal("start_failed", ["reason": .string("chain_stopped")]).chainStopped == nil)
        #expect(refusal("start_failed", ["reason": .string("chain_stopped"), "chain_root_task_id": .string("")]).chainStopped == nil)
        #expect(refusal("start_failed", ["reason": .string("chain_stopped"), "chain_root_task_id": .number(1)]).chainStopped == nil)
        #expect(ToolError.refused(code: "start_failed", message: "Continuation chain was cancelled").chainStopped == nil)
    }

    // MARK: Cancel cascade

    @Test(arguments: [
        ("ctl-task-cancel-settled.json", CancelCascadeObservation.Coverage.complete, false, 1),
        ("ctl-task-cancel-partial.json", .complete, false, 2),
        ("ctl-task-cancel-pending.json", .complete, false, 1),
        ("ctl-task-cancel-incomplete.json", .incomplete, false, 6),
        ("ctl-task-cancel-pending-child-withdrawal-unsettled.json", .incomplete, false, 2),
        ("ctl-task-cancel-refused-documents.json", .incomplete, false, 1),
        ("ctl-task-cancel-truncated.json", .incomplete, true, 100),
        ("ctl-task-cancel-unknown.json", .unknown, false, 0),
        ("ctl-task-cancel-unrecorded.json", .complete, false, 1)
    ])
    func givenCancelFixture_whenReadingObservation_thenCoverageTruncationAndRowsDecode(
        _ name: String, _ coverage: CancelCascadeObservation.Coverage, _ truncated: Bool, _ rows: Int
    ) throws {
        // given
        let result = try cancelResult(name)

        // when
        let observation = try #require(CancelCascadeObservation.reading(in: result).value)

        // then
        #expect(observation.coverage == coverage)
        #expect(observation.truncated == truncated)
        #expect(observation.items.count == rows)
        #expect(observation.scope == "recorded_tasks_and_pending_launches")
        #expect(observation.observedAt == "2026-10-15T00:00:00+00:00")
    }

    @Test
    func givenPartialCancelFixture_whenReadingRows_thenStateBasisAndStatusStaySeparate() throws {
        // given
        let result = try cancelResult("ctl-task-cancel-partial.json")

        // when
        let items = try #require(CancelCascadeObservation.reading(in: result).value?.items)

        // then
        #expect(items[0].state == .stopped)
        #expect(items[0].basis == .observedSettlement)
        #expect(items[1].state == .running)
        #expect(items[1].basis == .confirmedLiveIdentity)
        #expect(items[1].status == "completed")
        let pending = try cancelResult("ctl-task-cancel-pending-child-withdrawal-unsettled.json")
        #expect(CancelCascadeObservation.reading(in: pending).value?.items[1].state == .unknown)
        #expect(CancelCascadeObservation.reading(in: pending).value?.items[1].basis == .insufficientEvidence)
        let notStarted = try cancelResult("ctl-task-cancel-pending.json")
        #expect(CancelCascadeObservation.reading(in: notStarted).value?.items[0].basis == .provenNotStarted)
    }

    @Test
    func givenLegacyCancelResultWithoutObservation_whenRead_thenItIsAbsentAndSummaryIsUnchanged() {
        // given
        let result: [String: JSONValue] = ["status": .string("cancelled"), "cascade": .object(["cancelled_descendants": .array([])])]

        // then
        #expect(CancelCascadeObservation.reading(in: result) == .absent)
        #expect(CancelCascadeObservation.reading(in: ["status": .string("cancelled")]) == .absent)
        #expect(CascadeSummary.describe(result) == "Cancel sent · status cancelled")
    }

    @Test
    func givenDamagedObservation_whenRead_thenItIsMalformedAndUnknownValuesSurvive() throws {
        // given
        let base = try #require(CancelCascadeObservation.reading(in: try cancelResult("ctl-task-cancel-partial.json")).value)
        let row: [String: JSONValue] = ["task_id": .string("t"), "state": .string("future"), "basis": .string("future_basis"), "status": .null]
        let good: [String: JSONValue] = [
            "scope": .string(base.scope), "observed_at": .string(base.observedAt), "coverage": .string("future_coverage"),
            "truncated": .bool(false), "items": .array([.object(row)])
        ]
        func wrap(_ observation: JSONValue) -> [String: JSONValue] { ["cascade": .object(["observation": observation])] }

        // when
        let tolerated = CancelCascadeObservation.reading(in: wrap(.object(good))).value

        // then
        #expect(tolerated?.coverage == .unrecognized("future_coverage"))
        #expect(tolerated?.items.first?.state == .unrecognized("future"))
        #expect(tolerated?.items.first?.basis == .unrecognized("future_basis"))
        #expect(tolerated?.items.first?.status == nil)
        var badTruncated = good
        badTruncated["truncated"] = .string("no")
        var missingScope = good
        missingScope["scope"] = nil
        var badItems = good
        badItems["items"] = .object([:])
        var badRow = good
        badRow["items"] = .array([.object(["task_id": .string("t"), "state": .string("stopped")])])
        var tooMany = good
        tooMany["items"] = .array(Array(repeating: .object(row), count: 101))
        for damaged in [JSONValue.object(badTruncated), .object(missingScope), .object(badItems), .object(badRow), .object(tooMany), .null, .array([])] {
            #expect(CancelCascadeObservation.reading(in: wrap(damaged)) == .malformed)
        }
        var atBound = good
        atBound["items"] = .array(Array(repeating: .object(row), count: 100))
        #expect(CancelCascadeObservation.reading(in: wrap(.object(atBound))).value?.items.count == 100)
    }

    @Test
    func givenCancelFixtures_whenSummarised_thenWordingIgnoresTheObservation() throws {
        // given
        let result = try cancelResult("ctl-task-cancel-partial.json")
        var stripped = result
        var cascade = try #require(result["cascade"]?.objectValue)
        cascade["observation"] = nil
        stripped["cascade"] = .object(cascade)

        // then
        #expect(CascadeSummary.describe(result) == CascadeSummary.describe(stripped))
    }

    // MARK: Task artifacts

    @Test(arguments: ["ctl-task-artifacts-empty.json", "ctl-task-artifacts-next-page.json", "ctl-task-artifacts-populated.json",
                      "ctl-task-artifacts-unavailable.json"])
    func givenArtifactFixture_whenDecoded_thenPageSurvivesWithRegisteredObservation(_ name: String) throws {
        // given
        let payload = try artifactPayload(name)
        let taskID = try #require(payload["task_id"]?.stringValue)

        // when
        let page = try #require(TaskArtifactPage(raw: payload, taskID: taskID))

        // then
        #expect(page.items.count == payload["items"]?.arrayValue?.count)
        for item in page.items {
            #expect(item.registeredObservation != nil)
        }
        if name == "ctl-task-artifacts-populated.json" || name == "ctl-task-artifacts-next-page.json" {
            #expect(page.items.first?.registeredObservation == ArtifactRegisteredObservation(raw: [
                "device": .number(1), "inode": .number(2), "size": .number(6), "mtime_ns": .number(0)
            ]))
        }
        if name == "ctl-task-artifacts-unavailable.json" {
            #expect(page.state == "unavailable")
        }
    }

    @Test
    func givenArtifactItemWithoutRegisteredObservation_whenDecoded_thenItIsNilButPageIsAccepted() throws {
        // given
        var payload = try artifactPayload("ctl-task-artifacts-populated.json")
        var items = try #require(payload["items"]?.arrayValue)
        var item = try #require(items[0].objectValue)
        item["registered_observation"] = nil
        items[0] = .object(item)
        payload["items"] = .array(items)

        // when
        let page = TaskArtifactPage(raw: payload, taskID: "task-artifacts-owner")

        // then
        #expect(page?.items.first?.registeredObservation == nil)
        #expect(page?.items.count == items.count)
    }

    @Test
    func givenRealisticMtime_whenDecoded_thenValueIsTheApproximateDouble() throws {
        // given
        let raw: [String: JSONValue] = ["device": .number(16_777_231), "inode": .number(8_123_456), "size": .number(4096),
                                        "mtime_ns": .number(1_700_000_000_123_456_789)]

        // when
        let observation = try #require(ArtifactRegisteredObservation(raw: raw))

        // then
        #expect(observation.approximateMtimeNS == Double(1_700_000_000_123_456_789))
        #expect(observation.device == 16_777_231)
    }

    @Test(arguments: [JSONValue.null, .string("x"), .object([:]),
                      .object(["device": .number(1), "inode": .number(2), "size": .number(3)]),
                      .object(["device": .number(1), "inode": .number(2), "size": .string("3"), "mtime_ns": .number(4)]),
                      .object(["device": .number(1), "inode": .number(2), "size": .number(3.5, isInteger: false), "mtime_ns": .number(4)])])
    func givenDamagedRegisteredObservation_whenDecoded_thenPageIsRejected(_ damaged: JSONValue) throws {
        // given
        var payload = try artifactPayload("ctl-task-artifacts-populated.json")
        var items = try #require(payload["items"]?.arrayValue)
        var item = try #require(items[0].objectValue)
        item["registered_observation"] = damaged
        items[0] = .object(item)
        payload["items"] = .array(items)

        // then
        #expect(TaskArtifactPage(raw: payload, taskID: "task-artifacts-owner") == nil)
    }

    @Test(arguments: [
        ("ctl-task-artifacts-page-error.json", WireObservation<ArtifactErrorReason>.present(.cursorInvalid)),
        ("ctl-task-artifacts-preparing.json", .present(.ownershipPreparing))
    ])
    func givenStructuredArtifactErrorFixture_whenReadingReason_thenReasonIsTyped(
        _ name: String, _ expected: WireObservation<ArtifactErrorReason>
    ) throws {
        // when
        let result = CtlDocument.decode(stdout: try fixture(name), stderr: "", exitCode: 1, command: "task-artifacts").requiringSuccess()

        // then
        guard case .failure(let error) = result, case .structuredRefusal(let code, _, _) = error else {
            Issue.record("expected a structured refusal for \(name)")
            return
        }
        #expect(code == "artifact_error")
        #expect(error.artifactErrorReason == expected)
    }

    @Test
    func givenPlainArtifactErrorFixture_whenDecoded_thenItIsAPlainRefusalWithoutReason() throws {
        // when
        let result = CtlDocument.decode(stdout: try fixture("ctl-task-artifacts-error.json"), stderr: "", exitCode: 1,
                                        command: "task-artifacts")
.requiringSuccess()

        // then
        guard case .failure(let error) = result, case .refused(let code, _) = error else {
            Issue.record("expected a plain refusal")
            return
        }
        #expect(code == "artifact_error")
        #expect(error.artifactErrorReason == .absent)
    }

    @Test
    func givenReasonValues_whenRead_thenStaleUnknownAndMalformedAreDistinct() {
        // given
        func error(_ reason: JSONValue?, code: String = "artifact_error") -> ToolError {
            .structuredRefusal(code: code, message: "m", data: reason.map { ["reason": $0] } ?? ["other": .bool(true)])
        }

        // then
        #expect(error(.string("cursor_stale")).artifactErrorReason == .present(.cursorStale))
        #expect(error(.string("future")).artifactErrorReason == .present(.unrecognized("future")))
        #expect(error(.number(1)).artifactErrorReason == .malformed)
        #expect(error(nil).artifactErrorReason == .absent)
        #expect(error(.string("cursor_stale"), code: "other").artifactErrorReason == .absent)
        #expect(ToolError.refused(code: "artifact_error", message: "m").artifactErrorReason == .absent)
    }

    @Test
    func givenAdvertisingAndMissingHandshakes_whenReadingArtifacts_thenCapabilityGatesTheCall() async throws {
        // given
        let home = "/tmp/harflow-fixture-home"
        let populated = try fixture("ctl-task-artifacts-populated.json")
        let withCapability = RecordingRunner { call in
            call.arguments.first == "version-info" ? ProcessOutput(exitCode: 0, stdout: (try? fixture("version-info.json")) ?? Data(), stderr: "")
                : ProcessOutput(exitCode: 0, stdout: populated, stderr: "")
        }
        let without = RecordingRunner { _ in
            ProcessOutput(exitCode: 0, stdout: (try? fixture("invalid-s05-missing-task-artifacts.json")) ?? Data(), stderr: "")
        }

        // when
        let accepted = await CtlClient(executable: "/runtime/harflow-ctl", environment: ["HOME": home], runner: withCapability)
            .taskArtifacts("task-artifacts-owner")
        let refused = await CtlClient(executable: "/runtime/harflow-ctl", environment: ["HOME": home], runner: without)
            .taskArtifacts("task-artifacts-owner")

        // then
        #expect(try accepted.get().items.count == 2)
        guard case .failure(.unsupportedCommand(_, let command, let detail)) = refused else {
            Issue.record("missing task-artifacts.v1 did not refuse")
            return
        }
        #expect(command == "task-artifacts")
        #expect(detail.contains(CtlCapability.taskArtifacts))
        #expect(without.calls.isEmpty)
    }

    // MARK: Capability constants

    @Test
    func givenNewCapabilities_whenAdvertisedByFixtureHandshake_thenConstantsMatchTheWireNames() throws {
        // given
        let data = try fixture("version-info.json")
        let info = try VersionInfoDocument.decode(
            stdout: data, context: .derived(environment: ["HOME": "/tmp/harflow-fixture-home"])
        )
.get()

        // then
        for capability in [CtlCapability.taskContinue, CtlCapability.taskArtifacts, CtlCapability.taskContinuationStop,
                           CtlCapability.taskCancelCascade] {
            #expect(info.capabilities.contains(capability), "\(capability)")
        }
        #expect(CtlCapability.taskContinue == "task-continue.v1")
        #expect(CtlCapability.taskArtifacts == "task-artifacts.v1")
        #expect(CtlCapability.taskContinuationStop == "task-continuation-stop.v1")
        #expect(CtlCapability.taskCancelCascade == "task-cancel-cascade.v1")
    }
}
