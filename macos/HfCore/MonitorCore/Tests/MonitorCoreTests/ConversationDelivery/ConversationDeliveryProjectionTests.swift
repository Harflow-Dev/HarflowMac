import Foundation
@testable import MonitorCore
import Testing

// MARK: - Required-field mutations

/// SYNTHETIC removal of one required projection key from the `empty` fixture.
enum ProjectionRequiredKey: String, CaseIterable, Sendable {
    case contract, expected, closed, cumulativeIssuances = "cumulative_issuances", accounting, runtimeFault = "runtime_fault", messages
}

// MARK: - ConversationDeliveryProjectionTests

/// Projection decoding edges and reconciliation. Reconciliation uses the `cancelled`,
/// `promoted-now` and `bounded-window` fixtures; every mutation is SYNTHETIC.
struct ConversationDeliveryProjectionTests {
    @Test func givenProjectionWithoutProgress_whenDecoded_thenItDecodesWithNilProgress() throws {
        // given: SYNTHETIC; the engine emits progress conditionally
        var raw = try ConvFixture.result("queue-fifo")
        raw["progress"] = nil
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw))
        // then
        #expect(projection.progress == nil)
        #expect(projection.messages.count == 2)
    }

    @Test(arguments: ProjectionRequiredKey.allCases)
    func givenMissingRequiredField_whenDecoded_thenItFailsClosed(key: ProjectionRequiredKey) throws {
        // given
        var raw = try ConvFixture.result("empty")
        raw[key.rawValue] = nil
        // when / then
        #expect(ConversationDeliveryProjection(raw: raw) == nil)
    }

    @Test(arguments: ["source_generation", "source_turn_id", "source_epoch", "original_target_task_id"])
    func givenMessageMissingRequiredField_whenDecoded_thenItFailsClosed(key: String) throws {
        // given: SYNTHETIC removal of one always-emitted message key
        var raw = try ConvFixture.result("queue-fifo")
        var messages = try #require(raw["messages"]?.arrayValue)
        var first = try #require(messages[0].objectValue)
        #expect(first[key] != nil)
        first[key] = nil
        messages[0] = .object(first)
        raw["messages"] = .array(messages)
        // when / then
        #expect(ConversationDeliveryProjection(raw: raw) == nil)
    }

    @Test(arguments: ["cost_basis", "last_cost_basis", "observed_cost_usd", "last_cost_usd"])
    func givenAccountingMissingRequiredField_whenDecoded_thenItFailsClosed(key: String) throws {
        // given: SYNTHETIC removal of one always-emitted accounting key
        var raw = try ConvFixture.result("empty")
        var accounting = try #require(raw["accounting"]?.objectValue)
        #expect(accounting[key] != nil)
        accounting[key] = nil
        raw["accounting"] = .object(accounting)
        // when / then
        #expect(ConversationDeliveryProjection(raw: raw) == nil)
    }

    @Test(arguments: ["code", "generation", "turn_id"])
    func givenRuntimeFaultMissingField_whenDecoded_thenItFailsClosed(key: String) throws {
        // given: runtime-unknown fixture with one fault key removed (SYNTHETIC mutation)
        var raw = try ConvFixture.result("runtime-unknown")
        var fault = try #require(raw["runtime_fault"]?.objectValue)
        #expect(fault[key] != nil)
        fault[key] = nil
        raw["runtime_fault"] = .object(fault)
        // when / then
        #expect(ConversationDeliveryProjection(raw: raw) == nil)
    }

    @Test func givenNullCostValues_whenDecoded_thenTheyDecodeAsNilAndNeverZero() throws {
        // given: the empty fixture emits null for both cost values
        let raw = try ConvFixture.result("empty")
        #expect(raw["accounting"]?.objectValue?["observed_cost_usd"] == .null)
        #expect(raw["accounting"]?.objectValue?["last_cost_usd"] == .null)
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw))
        // then
        #expect(projection.accounting.observedCostUSD == nil)
        #expect(projection.accounting.lastCostUSD == nil)
    }

    @Test func givenNumericCostValues_whenDecoded_thenTheyAreKept() throws {
        // given: SYNTHETIC numeric costs
        var raw = try ConvFixture.result("empty")
        var accounting = try #require(raw["accounting"]?.objectValue)
        accounting["observed_cost_usd"] = .number(0.5)
        accounting["last_cost_usd"] = .number(0.25)
        raw["accounting"] = .object(accounting)
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw))
        // then
        #expect(projection.accounting.observedCostUSD == 0.5)
        #expect(projection.accounting.lastCostUSD == 0.25)
    }

    @Test func givenNonNumericCostValue_whenDecoded_thenItFailsClosed() throws {
        // given: SYNTHETIC
        var raw = try ConvFixture.result("empty")
        var accounting = try #require(raw["accounting"]?.objectValue)
        accounting["observed_cost_usd"] = .string("1.0")
        raw["accounting"] = .object(accounting)
        // when / then
        #expect(ConversationDeliveryProjection(raw: raw) == nil)
    }

    @Test func givenNullOriginalTargetTaskId_whenDecoded_thenItDecodesAsNil() throws {
        // given: SYNTHETIC; null means the message was never retargeted
        var raw = try ConvFixture.result("queue-fifo")
        var messages = try #require(raw["messages"]?.arrayValue)
        var first = try #require(messages[0].objectValue)
        first["original_target_task_id"] = .null
        messages[0] = .object(first)
        raw["messages"] = .array(messages)
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw))
        // then
        #expect(projection.messages[0].originalTargetTaskID == nil)
        #expect(projection.messages[1].originalTargetTaskID != nil)
    }

    @Test func givenConditionalMessageFieldsAbsent_whenDecoded_thenItStillDecodes() throws {
        // given: SYNTHETIC; destination, receipt and the two operation ids are conditional
        var raw = try ConvFixture.result("now-claimed")
        var messages = try #require(raw["messages"]?.arrayValue)
        var last = try #require(messages[2].objectValue)
        for key in ["destination", "receipt", "promotion_request_id", "cancellation_request_id"] { last[key] = nil }
        messages[2] = .object(last)
        raw["messages"] = .array(messages)
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw))
        // then
        #expect(projection.messages[2].destination == nil)
        #expect(projection.messages[2].receipt == nil)
        #expect(projection.messages[2].promotionRequestID == nil)
        #expect(projection.messages[2].cancellationRequestID == nil)
    }

    @Test func givenForeignContract_whenDecoded_thenItFailsClosed() throws {
        // given
        var raw = try ConvFixture.result("empty")
        raw["contract"] = .string("conversation_delivery_v2")
        // when / then
        #expect(ConversationDeliveryProjection(raw: raw) == nil)
    }

    @Test func givenMalformedProgressOrMessage_whenDecoded_thenItFailsClosed() throws {
        // given
        var badProgress = try ConvFixture.result("empty")
        badProgress["progress"] = .object(["phase": .string("starting")])
        var badMessage = try ConvFixture.result("queue-fifo")
        badMessage["messages"] = .array([.object(["request_id": .string("not-a-uuid")])])
        // when / then
        #expect(ConversationDeliveryProjection(raw: badProgress) == nil)
        #expect(ConversationDeliveryProjection(raw: badMessage) == nil)
    }

    @Test func givenUnrecognizedStatusPhaseDeliveryAndOrigin_whenDecoded_thenValuesAreKeptAndMatchNoKnownConstant() throws {
        // given: SYNTHETIC future values in the now-claimed fixture
        var raw = try ConvFixture.result("now-claimed")
        var messages = try #require(raw["messages"]?.arrayValue)
        var last = try #require(messages[2].objectValue)
        last["status"] = .string("future_status")
        last["delivery"] = .string("future_delivery")
        var destination = try #require(last["destination"]?.objectValue)
        destination["origin"] = .string("future_origin")
        last["destination"] = .object(destination)
        messages[2] = .object(last)
        raw["messages"] = .array(messages)
        var progress = try #require(raw["progress"]?.objectValue)
        progress["phase"] = .string("future_phase")
        raw["progress"] = .object(progress)
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw))
        let message = projection.messages[2]
        // then
        #expect(message.status.rawValue == "future_status")
        for known in [ConversationDeliveryMessage.Status.queued, .claimed, .consumed, .unknown, .cancelled] { #expect(message.status != known) }
        #expect(message.delivery != .queue && message.delivery != .now)
        #expect(!message.hasNowPriority)
        #expect(message.destination?.origin != .queueDrain && message.destination?.origin != .nowDelivery)
        #expect(projection.progress?.phase.rawValue == "future_phase")
        #expect(projection.progress?.phase != .unknown)
        #expect(projection.progress?.phase != .closed)
    }

    @Test func givenAdditiveKeys_whenDecoded_thenTheyStayInRaw() throws {
        // given: SYNTHETIC additive keys at projection and message level
        var raw = try ConvFixture.result("queue-fifo")
        raw["future_top"] = .string("x")
        var messages = try #require(raw["messages"]?.arrayValue)
        var first = try #require(messages[0].objectValue)
        first["future_message"] = .bool(true)
        messages[0] = .object(first)
        raw["messages"] = .array(messages)
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw))
        // then
        #expect(projection.raw["future_top"]?.stringValue == "x")
        #expect(projection.messages[0].raw["future_message"] == .bool(true))
    }

    @Test(arguments: ["promoted-now", "cancelled"])
    func givenFixtureProjection_whenMatchingEachIdField_thenRetainedReportsTheMatchedField(stem: String) throws {
        // given
        let projection = try ConvFixture.projection(stem)
        let promoted = stem == "promoted-now"
        // when
        let byRequest = projection.reconciliation(for: ConvID.message)
        let byOperation = projection.reconciliation(for: promoted ? ConvID.promote : ConvID.cancel)
        let other = projection.reconciliation(for: ConvID.second)
        // then
        guard case .retained(let first, .requestID) = byRequest else { Issue.record("expected requestID match, got \(byRequest)"); return }
        #expect(first.requestID == ConvID.message)
        guard case .retained(let controlled, let field) = byOperation else { Issue.record("expected retained, got \(byOperation)"); return }
        #expect(controlled.requestID == ConvID.message)
        #expect(field == (promoted ? .promotionRequestID : .cancellationRequestID))
        guard case .retained(let second, .requestID) = other else { Issue.record("expected second message, got \(other)"); return }
        #expect(second.sequence == 2)
    }

    @Test func givenUUIDOverload_whenReconciling_thenItMatchesTheLowercaseText() throws {
        // given
        let projection = try ConvFixture.projection("promoted-now")
        // when
        let byUUID = projection.reconciliation(for: ConvID.uuid(ConvID.promote))
        // then
        #expect(byUUID == projection.reconciliation(for: ConvID.promote))
        guard case .retained(_, .promotionRequestID) = byUUID else { Issue.record("expected promotion match, got \(byUUID)"); return }
    }

    @Test func givenAbsentId_whenReconciling_thenOnlyAbsenceFromTheRetainedWindowIsReported() throws {
        // given
        let projection = try ConvFixture.projection("bounded-window")
        // when
        let absent = projection.reconciliation(for: ConvID.absent)
        // then
        #expect(absent == .absentFromRetainedWindow)
        #expect(try ConvFixture.projection("empty").reconciliation(for: ConvID.message) == .absentFromRetainedWindow)
    }

    @Test func givenBoundedWindowFixture_whenReconciling_thenRetainedMessagesAreFoundAndCompactedOnesAreNotClaimed() throws {
        // given
        let projection = try ConvFixture.projection("bounded-window")
        let retained = try #require(projection.messages.last)
        // when
        let found = projection.reconciliation(for: retained.requestID)
        // then
        #expect(found == .retained(retained, matchedField: .requestID))
        #expect(projection.reconciliation(for: ConvID.message) == .absentFromRetainedWindow)
    }

    @Test func givenTargetOfWorkflowActivation_whenDecoded_thenTargetKeepsRunActivationAndTask() throws {
        // given: SYNTHETIC target added to a fixture
        var raw = try ConvFixture.result("empty")
        raw["target"] = .object(["kind": .string("workflow_activation"), "workflow_run_id": .string(ConvID.run),
                                 "activation_id": .string(ConvID.activation), "task_id": .string(ConvID.head)])
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw, requestedTaskID: ConvID.head))
        // then
        #expect(projection.target == convWorkflowTarget)
        #expect(projection.expected.headTaskID == ConvID.head)
    }

    @Test func givenHeadTaskDifferingFromRequestedId_whenDecodedWithoutTarget_thenHeadTaskIsNotCompared() throws {
        // given: expected.head_task_id (...00a) differs from the id the caller asked about
        let raw = try ConvFixture.result("empty")
        // when
        let projection = ConversationDeliveryProjection(raw: raw, requestedTaskID: "some-other-task")
        // then
        #expect(projection != nil)
    }

    @Test func givenUnknownTargetKind_whenDecoded_thenItFailsClosed() throws {
        // given: SYNTHETIC
        var raw = try ConvFixture.result("empty")
        raw["target"] = .object(["kind": .string("future_kind"), "task_id": .string(ConvID.head)])
        // when / then
        #expect(ConversationDeliveryProjection(raw: raw) == nil)
    }

    @Test func givenProjectionWitness_whenBuildingARequest_thenWitnessFieldsMatchTheFixture() throws {
        // given
        let projection = try ConvFixture.projection("delivery-unknown")
        // when
        let request = try ConversationDeliverySendRequest(requestID: ConvID.uuid(ConvID.second), witness: projection.expected,
                                                          target: .task(taskID: ConvID.head), mode: .queue, text: "hi")
        // then
        let expected = try #require(decodedBody(request.body)["expected"]?.objectValue)
        #expect(expected["generation"]?.wireIntegerValue == 2)
        #expect(expected["turn_id"]?.stringValue == "00000000-0000-0000-0000-00000000000c")
        #expect(expected["ledger_epoch"]?.wireIntegerValue == 0)
    }
}
