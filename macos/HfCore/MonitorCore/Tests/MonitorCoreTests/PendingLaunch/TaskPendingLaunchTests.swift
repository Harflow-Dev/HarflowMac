import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskPendingLaunchTests

@Suite struct TaskPendingLaunchTests {
    private let target = String(repeating: "a", count: 32)
    private let capabilities = [CtlCapability.taskPendingLaunch, CtlCapability.taskCancelCascade]

    private func raw(_ name: String) throws -> [String: JSONValue] {
        try #require(JSONValue.parse(ConvFixture.data("ctl-task-\(name).json"))?["result"]?.objectValue)
    }

    private func runner(_ answer: ConvResult, capabilities: [String]? = nil) -> ConversationRunner {
        let offered = capabilities ?? self.capabilities
        return ConversationRunner(probe: { environment, _ in
            .success(conversationProbe(environment, capability: false, extraCapabilities: offered))
        }, command: { _, _ in answer })
    }

    @Test func givenCanonicalStates_whenDecoded_thenSeparateMetadataAndMechanism() throws {
        // given / when
        let page = try #require(TaskPendingLaunchPage(raw: raw("pending-states")))
        // then
        #expect(page.items.compactMap { $0.launch?.state } == [.reserved, .claimed, .waitingForResources, .granted, .notStarted])
        #expect(page.items.map(\.cancelSupport) == [.unsupported, .unsupported, .supported, .supported, .unsupported])
        #expect(page.coverage == .complete)
    }

    @Test(arguments: ["pending-empty", "pending-refused", "pending-next-page"])
    func givenCanonicalPages_whenDecoded_thenCoverageRemainsExplicit(name: String) throws {
        // given / when
        let page = try #require(TaskPendingLaunchPage(raw: raw(name)))
        // then
        if name == "pending-empty" { #expect(page.items.isEmpty && page.coverage == .complete) }
        if name == "pending-refused" {
            #expect(page.coverage == .unknown)
            #expect(page.items.last?.launch == nil)
            #expect(page.items.last?.cancelSupport == nil)
        }
        if page.hasMore { #expect(page.nextCursor != nil && page.coverage == .unknown) }
    }

    @Test(arguments: ["pending", "recorded", "not-found", "refused", "unknown"])
    func givenCanonicalLookup_whenDecoded_thenExactIdentityRequired(name: String) throws {
        // given
        let value = try raw("pending-status-\(name)")
        let id = try #require(value["task_id"]?.stringValue)
        // when / then
        #expect(TaskPendingLaunchLookup(raw: value, requestedTaskID: id) != nil)
        #expect(TaskPendingLaunchLookup(raw: value, requestedTaskID: "different") == nil)
    }

    @Test func givenUnknownStateAndDisposition_whenDecoded_thenNoTrustedLabels() throws {
        // given
        var row = try #require(raw("pending-states")["items"]?.arrayValue?.first?.objectValue)
        var launch = try #require(row["launch"]?.objectValue)
        launch["state"] = .string("future")
        row["launch"] = .object(launch)
        // when / then
        #expect(TaskPendingLaunchItem(raw: row)?.launch == nil)
        row["disposition"] = .string("future")
        #expect(TaskPendingLaunchItem(raw: row)?.disposition == .unrecognized("future"))
        #expect(TaskPendingLaunchItem(raw: row)?.cancelSupport == nil)
    }

    @Test(arguments: ["state", "disposition", "cancel_support"])
    func givenFutureObservationAlongsideHealthyRows_whenProducerCoverageComplete_thenNeighborsSurviveWithoutClientCompleteness(field: String) throws {
        // given
        var value = try raw("pending-states")
        var rows = try #require(value["items"]?.arrayValue)
        var future = try #require(rows[0].objectValue)
        if field == "state" {
            var launch = try #require(future["launch"]?.objectValue)
            launch["state"] = .string("future")
            future["launch"] = .object(launch)
        } else {
            future[field] = .string("future")
        }
        rows[0] = .object(future)
        value["items"] = .array(rows)
        // when
        let page = try #require(TaskPendingLaunchPage(raw: value))
        // then
        #expect(page.coverage == .complete && page.hasUnsupportedObservations)
        #expect(page.items.count == 5 && page.items[1].launch?.state == .claimed)
        #expect(page.items[0].hasUnsupportedObservations)
        if field != "cancel_support" {
            #expect(page.items[0].launch == nil && page.items[0].cancelSupport == nil)
        } else {
            #expect(page.items[0].cancelSupport == .unrecognized("future"))
        }
    }

    @Test(arguments: ["refused", "unknown", "recorded", "not_found"])
    func givenKnownContradictoryRow_whenProducerCoverageComplete_thenRejected(disposition: String) throws {
        // given
        var value = try raw("pending-states")
        var rows = try #require(value["items"]?.arrayValue)
        let id = try #require(rows[0]["task_id"]?.stringValue)
        rows[0] = .object(["task_id": .string(id), "disposition": .string(disposition),
                           "code": .string("fixture"), "check": .string("fixture")])
        value["items"] = .array(rows)
        // when / then
        #expect(TaskPendingLaunchPage(raw: value) == nil)
    }

    @Test func givenFutureCoverage_whenDecoded_thenClientCompletenessRemainsUnsupported() throws {
        // given
        var value = try raw("pending-states")
        value["coverage"] = .string("future")
        // when
        let page = try #require(TaskPendingLaunchPage(raw: value))
        // then
        #expect(page.coverage == .unrecognized("future") && page.hasUnsupportedObservations)
        #expect(page.items.allSatisfy { !$0.hasUnsupportedObservations })
    }

    @Test func givenMalformedFields_whenDecoded_thenNoSuccessfulEmptyFallback() throws {
        // given
        let page = try raw("pending-states")
        let bad: [(String, JSONValue)] = [
            ("scope", .string("other")), ("namespace_revision", .string("bad")),
            ("examined_count", .number(4)), ("examined_count", .bool(true)),
            ("invalid_name_count", .number(-1)), ("has_more", .bool(true)),
            ("next_cursor", .string("unpaired")), ("namespace_complete", .bool(false)),
            ("bound", .string("read_budget")), ("items", .null)
        ]
        // when / then
        for (key, value) in bad {
            var changed = page
            changed[key] = value
            #expect(TaskPendingLaunchPage(raw: changed) == nil, "\(key)")
        }
        var additive = page
        additive["future"] = .bool(true)
        #expect(TaskPendingLaunchPage(raw: additive) != nil)
    }

    @Test(arguments: ["", "-option", "a/b", "é", String(repeating: "a", count: 65)])
    func givenInvalidIdentity_whenConstructed_thenRefused(id: String) {
        // given / when / then
        #expect(!TaskPendingLaunchWire.isFullID(id))
        #expect(TaskPendingLaunchStopRequest(taskID: id) == nil)
    }

    @Test func givenQualifiedReads_whenInvoked_thenExactArgvAndFreshProbe() async throws {
        // given
        let runner = runner(convResult(try raw("pending-status-pending")))
        let client = conversationClient(runner)
        // when
        let result = await client.taskPendingStatus(taskID: target)
        // then
        #expect(try result.get().item.taskID == target)
        #expect(runner.allCalls == [["version-info", "--json"], ["task-pending-status", "--task-id=\(target)", "--json"]])
        let pageRunner = self.runner(convResult(try raw("pending-empty")))
        _ = await conversationClient(pageRunner).taskPendingPage(limit: 7, cursor: "-opaque")
        #expect(pageRunner.commandCalls == [["task-pending-page", "--limit=7", "--cursor=-opaque", "--json"]])
    }

    @Test func givenBadRequestOrMissingCapability_whenRead_thenNoDispatch() async {
        // given
        let runner = runner(convRaw(exit: 0), capabilities: [])
        let client = conversationClient(runner)
        // when
        _ = await client.taskPendingPage(limit: 0)
        _ = await client.taskPendingPage(cursor: String(repeating: "é", count: 2049))
        _ = await client.taskPendingStatus(taskID: "-bad")
        // then
        #expect(runner.allCalls.isEmpty)
        _ = await client.taskPendingPage()
        #expect(runner.probeCount == 1 && runner.commandCalls.isEmpty)
    }

    @Test func givenOversizedMalformedRead_whenReceived_thenBudgetFailurePrecedesParsing() async {
        // given
        let runner = runner(convRaw(exit: 0, stdout: String(repeating: "!", count: 131073)))
        // when
        let result = await conversationClient(runner).taskPendingPage()
        // then
        #expect(result == .failure(CtlClient.pendingMalformed("Pending document exceeded byte limit")))
    }

    @Test(arguments: [CtlCapability.taskPendingLaunch, CtlCapability.taskCancelCascade])
    func givenOneMissingStopCapability_whenStopped_thenNotDispatched(missing: String) async throws {
        // given
        let runner = runner(convRaw(exit: 0), capabilities: capabilities.filter { $0 != missing })
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        // when
        let result = await conversationClient(runner).stopPendingLaunch(request)
        // then
        #expect(result == .notDispatched(request, cause: .missingCapability(missing)))
        #expect(runner.probeCount == 1 && runner.commandCalls.isEmpty)
    }

    @Test func givenStopAcknowledgement_whenReceived_thenQualifiedTargetProofAndRawDiagnostics() async throws {
        // given
        let raw = try raw("cancel-pending")
        let runner = runner(convResult(raw))
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        // when
        let outcome = await conversationClient(runner).stopPendingLaunch(request)
        // then
        guard case .accepted(let receipt) = outcome else { Issue.record("Expected qualified acknowledgement"); return }
        #expect(receipt.targetIsProvenStopped)
        #expect(receipt.raw == raw)
        #expect(runner.commandCalls == [["cancel", "--json", "--", target]])
        #expect(runner.commandTimeouts == [300])
    }

    @Test func givenDamagedOrMismatchedStopReceipt_whenReceived_thenUncertain() async throws {
        // given
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        var missing = try raw("cancel-pending")
        missing["cascade"] = .null
        var wrong = try raw("cancel-pending")
        wrong["task_id"] = .string("other")
        // when / then
        for raw in [missing, wrong] {
            let runner = runner(convResult(raw))
            #expect(await conversationClient(runner).stopPendingLaunch(request) == .uncertain(request, cause: .receiptIdentityMismatch))
            #expect(runner.commandCalls.count == 1)
        }
    }

    @Test func givenUnsettledStop_whenReceived_thenAcknowledgementIsNotStopped() async throws {
        // given
        let raw = try raw("cancel-pending-child-withdrawal-unsettled")
        let id = try #require(raw["task_id"]?.stringValue)
        let request = try #require(TaskPendingLaunchStopRequest(taskID: id))
        // when
        let receipt = try #require(TaskPendingLaunchStopReceipt(raw: raw, matching: request))
        // then
        #expect(!receipt.targetIsProvenStopped)
    }

    @Test func givenPostDispatchErrorOrTimeout_whenStopped_thenNoRetryAndNoNonDispatchInference() async throws {
        // given
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        let errorRunner = runner(convError(code: "after_write", data: .object(["published": .bool(true)])))
        let timeoutRunner = runner(convRaw(exit: 0, timedOut: true))
        // when / then
        guard case .engineError(_, let error) = await conversationClient(errorRunner).stopPendingLaunch(request) else {
            Issue.record("Expected retained engine error"); return
        }
        #expect(error.data == ["published": .bool(true)])
        #expect(await conversationClient(timeoutRunner).stopPendingLaunch(request) == .uncertain(request, cause: .timedOut(seconds: 300)))
        #expect(errorRunner.commandCalls.count == 1 && timeoutRunner.commandCalls.count == 1)
    }

    @Test func givenSettlementVersusNotStarted_whenProven_thenEvidenceRemainsDistinct() throws {
        // given
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        let original = try raw("cancel-pending")
        let proven = try #require(TaskPendingLaunchStopReceipt(raw: original, matching: request))
        var changed = original
        var cascade = try #require(changed["cascade"]?.objectValue)
        var observation = try #require(cascade["observation"]?.objectValue)
        observation["items"] = .array([.object(["task_id": .string(target), "state": .string("stopped"),
                                               "basis": .string("observed_settlement"), "status": .string("cancelled")])])
        cascade["observation"] = .object(observation)
        changed["cascade"] = .object(cascade)
        // when
        let settled = try #require(TaskPendingLaunchStopReceipt(raw: changed, matching: request))
        // then
        #expect(proven.targetIsProvenNotStarted)
        #expect(settled.targetIsProvenStopped && !settled.targetIsProvenNotStarted)
        for key in ["coverage", "truncated", "items"] {
            var uncertain = observation
            uncertain[key] = key == "coverage" ? .string("unknown") : key == "truncated" ? .bool(true) : .array([])
            cascade["observation"] = .object(uncertain)
            changed["cascade"] = .object(cascade)
            #expect(TaskPendingLaunchStopReceipt(raw: changed, matching: request)?.targetIsProvenStopped == false)
        }
    }

    @Test func givenAlternatingCapabilities_whenStoppedTwice_thenNoCombinedHandshake() async throws {
        // given
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        let runner = ConversationRunner(probe: { environment, index in
            .success(conversationProbe(environment, extraCapabilities: [index == 1 ? CtlCapability.taskPendingLaunch : CtlCapability.taskCancelCascade]))
        }, command: { _, _ in Issue.record("No dispatch expected"); return convRaw(exit: 0) })
        let client = conversationClient(runner)
        // when / then
        #expect(await client.stopPendingLaunch(request) == .notDispatched(request, cause: .missingCapability(CtlCapability.taskCancelCascade)))
        #expect(await client.stopPendingLaunch(request) == .notDispatched(request, cause: .missingCapability(CtlCapability.taskPendingLaunch)))
        #expect(runner.commandCalls.isEmpty && runner.probeCount == 2)
    }

    @Test func givenPostDispatchGuardChange_whenAcknowledged_thenReceiptSurvives() async throws {
        // given
        let answer = convResult(try raw("cancel-pending"))
        let changed = Collector<Bool>()
        let runner = ConversationRunner(probe: { environment, _ in
            .success(conversationProbe(environment, extraCapabilities: [CtlCapability.taskPendingLaunch, CtlCapability.taskCancelCascade]))
        }, command: { _, _ in changed.add(true); return answer })
        var client = conversationClient(runner)
        client.operationIsCurrent = { changed.values.isEmpty }
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        // when / then
        guard case .accepted = await client.stopPendingLaunch(request) else { Issue.record("Dispatched receipt must survive supersede"); return }
        #expect(runner.commandCalls.count == 1)
    }

    @Test func givenMalformedMetadata_whenDecoded_thenRejected() throws {
        // given
        let original = try #require(raw("pending-states")["items"]?.arrayValue?.first?.objectValue)
        let metadata = try #require(original["launch"]?.objectValue)
        let invalid: [(String, JSONValue)] = [
            ("generation", .string("not-generation")), ("state", .null),
            ("title", .number(1)), ("title", .string(String(repeating: "é", count: 513))),
            ("repo_path", .string(String(repeating: "x", count: 4097))),
            ("lineage", .object(["parent_task_id": .string("bad/id")])),
            ("resource_names", .array([.string(String(repeating: "x", count: 257))])),
            ("resource_names", .array(Array(repeating: .string("x"), count: 101))),
            ("metadata_truncated", .number(0))
        ]
        // when / then
        for (key, value) in invalid {
            var changed = metadata
            changed[key] = value
            var row = original
            row["launch"] = .object(changed)
            #expect(TaskPendingLaunchItem(raw: row) == nil, "\(key)")
        }
    }

    @Test func givenUnusablePostDispatchOutputs_whenStopped_thenUncertainWithoutRetry() async throws {
        // given
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        let outputs: [ConvResult] = [
            convRaw(exit: 0, stdout: "not JSON"),
            convRaw(exit: 0, stdout: String(repeating: "!", count: CtlClient.conversationMutationStdoutCap + 1)),
            convRaw(exit: 2, stderr: "invalid choice"),
            .failure(.unreadable(tool: "runner", exitCode: 0, stderr: "lost response")),
            convRaw(exit: 0, stdout: "{\"product\":\"other\",\"format\":\"harflow.ctl\",\"v\":1,\"product_version\":\"0.0.12\",\"result\":{}}")
        ]
        // when / then
        for output in outputs {
            let runner = runner(output)
            guard case .uncertain = await conversationClient(runner).stopPendingLaunch(request) else {
                Issue.record("Post-dispatch output must remain uncertain"); continue
            }
            #expect(runner.commandCalls.count == 1)
        }
    }

    @Test func givenCancelledCaller_whenStopped_thenNoProbeOrDispatch() async throws {
        // given
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        let runner = runner(convRaw(exit: 0))
        let client = conversationClient(runner)
        // when
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.stopPendingLaunch(request)
        }
        let result = await task.value
        // then
        #expect(result == .notDispatched(request, cause: .cancelledBeforeLaunch))
        #expect(runner.allCalls.isEmpty)
    }

    @Test func givenInconsistentReadEnvelope_whenDecoded_thenUnavailable() async throws {
        // given
        let pending = try raw("pending-empty")
        let outputs = [convResult(pending, exit: 1),
                       convDocument(["result": .object(pending), "unknown": .object([:])], exit: 0)]
        // when / then
        for output in outputs {
            let result = await conversationClient(runner(output)).taskPendingPage()
            #expect(result == .failure(CtlClient.pendingMalformed("Inconsistent pending read envelope")))
        }
    }

    @Test func givenChangedGuardDuringProbe_whenStopped_thenNotDispatched() async throws {
        // given
        let current = Collector<Bool>()
        let runner = ConversationRunner(probe: { environment, _ in
            current.add(false)
            return .success(conversationProbe(environment, extraCapabilities: [CtlCapability.taskPendingLaunch, CtlCapability.taskCancelCascade]))
        }, command: { _, _ in Issue.record("No dispatch expected"); return convRaw(exit: 0) })
        var client = conversationClient(runner)
        client.operationIsCurrent = { current.values.isEmpty }
        let request = try #require(TaskPendingLaunchStopRequest(taskID: target))
        // when / then
        #expect(await client.stopPendingLaunch(request) == .notDispatched(request, cause: .cancelledBeforeLaunch))
        #expect(runner.commandCalls.isEmpty)
    }
}
