import Foundation
@testable import MonitorCore
import Testing

// MARK: - ConversationDeliveryReceiptFixtureTests

/// Fixture-backed receipts, refusals and status readbacks. The fixtures are synthetic recordings,
/// not live engine output.
struct ConversationDeliveryReceiptFixtureTests {
    @Test func givenSendAckFixture_whenSent_thenReceiptIsAcceptedWithMatchingIdentities() async throws {
        // given
        let request = try convSend()
        let runner = ConversationRunner { _, _ in ConvFixture.output("send-ack") }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        guard case .accepted(let receipt) = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(try ConvFixture.exitCode("send-ack") == 0)
        #expect(receipt.messageID == ConvID.message)
        #expect(receipt.taskID == ConvID.head)
        #expect(receipt.conversationID == ConvID.conversation)
        #expect(receipt.resolvedTaskID == ConvID.head)
        #expect(receipt.status == .queued)
        #expect(receipt.delivery == .queue)
        #expect(receipt.sequence == 1)
        #expect(receipt.workflowRunID == nil)
        #expect(receipt.raw == (try ConvFixture.result("send-ack")))
    }

    @Test func givenWorkflowSendAckFixture_whenSent_thenRunAndActivationAreMatchedAndOptionalFieldsAreAbsent() async throws {
        // given
        let request = try convSend(target: convWorkflowTarget)
        let runner = ConversationRunner { _, _ in ConvFixture.output("workflow-send-ack") }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        guard case .accepted(let receipt) = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(receipt.workflowRunID == ConvID.run)
        #expect(receipt.activationID == ConvID.activation)
        #expect(receipt.delivery == nil)
        #expect(receipt.sequence == nil)
        #expect(receipt.status == .queued)
    }

    @Test(arguments: [("cancel-ack", ConversationDeliveryControlOperation.cancel, ConvID.cancel, "cancelled"),
                      ("promote-ack", ConversationDeliveryControlOperation.promoteNow, ConvID.promote, "promoted")])
    func givenStandaloneControlFixture_whenControlled_thenReceiptCarriesControlFactsAndHeadTask(
        stem: String, operation: ConversationDeliveryControlOperation, operationID: String, status: String
    ) async throws {
        // given
        let request = try convControl(id: operationID, operation: operation)
        let runner = ConversationRunner { _, _ in ConvFixture.output(stem) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        guard case .accepted(let receipt) = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(receipt.operation == operation)
        #expect(receipt.requestID == operationID)
        #expect(receipt.messageRequestID == ConvID.message)
        #expect(receipt.status == status)
        #expect(receipt.taskID == ConvID.head)
        #expect(receipt.targetTaskID == ConvID.head)
        #expect(receipt.turnID == ConvID.turn)
        #expect(receipt.generation == 1)
        #expect(receipt.ledgerEpoch == 0)
    }

    @Test(arguments: [("workflow-cancel-ack", ConversationDeliveryControlOperation.cancel, ConvID.cancel),
                      ("workflow-promote-ack", ConversationDeliveryControlOperation.promoteNow, ConvID.promote)])
    func givenWorkflowControlFixture_whenControlled_thenReceiptHasNoStatusAndKeepsRunAndActivation(
        stem: String, operation: ConversationDeliveryControlOperation, operationID: String
    ) async throws {
        // given
        let request = try convControl(id: operationID, operation: operation, target: convWorkflowTarget)
        let runner = ConversationRunner { _, _ in ConvFixture.output(stem) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        guard case .accepted(let receipt) = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(receipt.status == nil)
        #expect(receipt.taskID == nil)
        #expect(receipt.conversationID == ConvID.conversation)
        #expect(receipt.workflowRunID == ConvID.run)
        #expect(receipt.activationID == ConvID.activation)
        #expect(receipt.messageRequestID == ConvID.message)
    }

    @Test(arguments: ConvFixtureFamily.refusals.sorted { $0.key < $1.key }.map { [$0.key, $0.value] })
    func givenRefusalFixture_whenSent_thenEngineErrorKeepsCodeAndRequest(pair: [String]) async throws {
        // given
        let stem = pair[0]
        let code = pair[1]
        let request = try convSend()
        let runner = ConversationRunner { _, _ in ConvFixture.output(stem) }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        #expect(try ConvFixture.exitCode(stem) == 1)
        #expect(outcome == .engineError(request, ConversationDeliveryEngineError(code: code, message: code, data: nil)))
    }

    @Test(arguments: ConvFixtureFamily.refusals.sorted { $0.key < $1.key }.map { [$0.key, $0.value] })
    func givenRefusalFixture_whenControlled_thenEngineErrorKeepsCodeAndRequest(pair: [String]) async throws {
        // given
        let stem = pair[0]
        let code = pair[1]
        let request = try convControl()
        let runner = ConversationRunner { _, _ in ConvFixture.output(stem) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome == .engineError(request, ConversationDeliveryEngineError(code: code, message: code, data: nil)))
    }

    @Test func givenConversationUnknownFixture_whenPrepared_thenRefusalIsDistinctFromUnknownStatus() async throws {
        // given
        let runner = ConversationRunner { _, _ in ConvFixture.output("refusal-conversation-unknown") }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        #expect(result == .failure(.refused(code: "conversation_unknown", message: "conversation_unknown")))
    }

    @Test func givenAvailableStatusFixture_whenRead_thenEnvelopeIsValidAndConversationFactsAreAtEnvelopeLevel() throws {
        // given
        let document = try ConvFixture.document("task-status-available")
        // when
        let conversation = try #require(document["task"]?.objectValue?["conversation"]?.objectValue)
        // then
        #expect(try ConvFixture.exitCode("task-status-available") == 0)
        #expect(WireEnvelope.validate(document, contract: .ctl) == nil)
        #expect(conversation["available"]?.boolValue == true)
        #expect(conversation["contract"]?.stringValue == "conversation_delivery_v1")
        #expect(conversation["conversation_id"]?.stringValue == ConvID.conversation)
        #expect(conversation["outstanding_count"]?.wireIntegerValue == 0)
        #expect(conversation["message_counts"]?.objectValue?["unknown"]?.wireIntegerValue == 0)
    }

    @Test func givenUnavailableStatusFixture_whenRead_thenLedgerUnavailableIsReportedWithoutCounts() throws {
        // given
        let document = try ConvFixture.document("task-status-unavailable")
        // when
        let conversation = try #require(document["task"]?.objectValue?["conversation"]?.objectValue)
        // then
        #expect(try ConvFixture.exitCode("task-status-unavailable") == 0)
        #expect(WireEnvelope.validate(document, contract: .ctl) == nil)
        #expect(conversation["available"]?.boolValue == false)
        #expect(conversation["code"]?.stringValue == "ledger_unavailable")
        #expect(conversation["message_counts"] == nil)
        #expect(document["task"]?.objectValue?["status"]?.stringValue == "completed")
    }
}
