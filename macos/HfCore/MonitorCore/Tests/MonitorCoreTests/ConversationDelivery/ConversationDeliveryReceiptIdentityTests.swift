import Foundation
@testable import MonitorCore
import Testing

// MARK: - Mutations

/// SYNTHETIC mutations of the `send-ack` and `workflow-send-ack` fixtures, one identity at a time.
enum SendReceiptMutation: String, CaseIterable, Sendable {
    case wrongContract, wrongMessageID, wrongTaskID, wrongConversationID, missingMessageID, missingTaskID, missingConversationID
    case nonStringStatus, nonIntegerSequence, nonStringDelivery

    func apply(_ raw: inout [String: JSONValue]) {
        switch self {
        case .wrongContract: raw["contract"] = .string("conversation_delivery_v2")
        case .wrongMessageID: raw["message_id"] = .string(ConvID.second)
        case .wrongTaskID: raw["task_id"] = .string("another-task")
        case .wrongConversationID: raw["conversation_id"] = .string("00000000-0000-0000-0000-0000000000aa")
        case .missingMessageID: raw["message_id"] = nil
        case .missingTaskID: raw["task_id"] = nil
        case .missingConversationID: raw["conversation_id"] = nil
        case .nonStringStatus: raw["status"] = .number(1)
        case .nonIntegerSequence: raw["sequence"] = .number(1.5, isInteger: false)
        case .nonStringDelivery: raw["delivery"] = .bool(true)
        }
    }
}

enum WorkflowSendMutation: String, CaseIterable, Sendable {
    case wrongRun, wrongActivation, missingRun, missingActivation

    func apply(_ raw: inout [String: JSONValue]) {
        switch self {
        case .wrongRun: raw["workflow_run_id"] = .string("other-run")
        case .wrongActivation: raw["activation_id"] = .string("other-activation")
        case .missingRun: raw["workflow_run_id"] = nil
        case .missingActivation: raw["activation_id"] = nil
        }
    }
}

enum ControlReceiptMutation: String, CaseIterable, Sendable {
    case wrongContract, wrongOperation, wrongRequestID, wrongMessageID, wrongTaskID, missingControl, wrongControlRequestID
    case wrongControlMessageRequestID, nonStringTurnID, nonIntegerGeneration

    func apply(_ raw: inout [String: JSONValue]) {
        var control = raw["control"]?.objectValue ?? [:]
        switch self {
        case .wrongContract: raw["contract"] = .string("conversation_delivery_v2")
        case .wrongOperation: raw["operation"] = .string("promote_now")
        case .wrongRequestID: raw["request_id"] = .string(ConvID.second)
        case .wrongMessageID: raw["message_id"] = .string(ConvID.second)
        case .wrongTaskID: raw["task_id"] = .string("another-task")
        case .missingControl: raw["control"] = nil
        case .wrongControlRequestID: control["request_id"] = .string(ConvID.second)
        case .wrongControlMessageRequestID: control["message_request_id"] = .string(ConvID.second)
        case .nonStringTurnID: control["turn_id"] = .number(3)
        case .nonIntegerGeneration: control["generation"] = .string("1")
        }
        if raw["control"] != nil { raw["control"] = .object(control) }
    }
}

enum WorkflowControlMutation: String, CaseIterable, Sendable {
    case wrongOperation, wrongConversationID, wrongRun, wrongActivation, missingReceipt, wrongReceiptRequestID, wrongReceiptMessageRequestID

    func apply(_ raw: inout [String: JSONValue]) {
        var receipt = raw["receipt"]?.objectValue ?? [:]
        switch self {
        case .wrongOperation: raw["operation"] = .string("promote_now")
        case .wrongConversationID: raw["conversation_id"] = .string("00000000-0000-0000-0000-0000000000aa")
        case .wrongRun: raw["workflow_run_id"] = .string("other-run")
        case .wrongActivation: raw["activation_id"] = .string("other-activation")
        case .missingReceipt: raw["receipt"] = nil
        case .wrongReceiptRequestID: receipt["request_id"] = .string(ConvID.second)
        case .wrongReceiptMessageRequestID: receipt["message_request_id"] = .string(ConvID.second)
        }
        if raw["receipt"] != nil { raw["receipt"] = .object(receipt) }
    }
}

// MARK: - ConversationDeliveryReceiptIdentityTests

/// A receipt that does not match the request it answers is uncertain, never accepted.
struct ConversationDeliveryReceiptIdentityTests {
    @Test(arguments: SendReceiptMutation.allCases)
    func givenSendReceiptWithBrokenIdentity_whenSent_thenUncertainAsMismatchWithTheRequest(mutation: SendReceiptMutation) async throws {
        // given: SYNTHETIC mutation of the send-ack fixture
        var raw = try ConvFixture.result("send-ack")
        mutation.apply(&raw)
        // when
        let run = try await convRunSend { convResult(raw) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .receiptIdentityMismatch))
    }

    @Test(arguments: WorkflowSendMutation.allCases)
    func givenWorkflowReceiptWithBrokenIdentity_whenSent_thenUncertainAsMismatch(mutation: WorkflowSendMutation) async throws {
        // given: SYNTHETIC mutation of the workflow-send-ack fixture
        var raw = try ConvFixture.result("workflow-send-ack")
        mutation.apply(&raw)
        let request = try convSend(target: convWorkflowTarget)
        let runner = ConversationRunner { _, _ in convResult(raw) }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    @Test func givenReceiptForAnotherRequest_whenSent_thenFixtureReceiptIsNotAcceptedForADifferentMessageId() async throws {
        // given: the send-ack fixture answers message ...065; the request carries another id
        let request = try convSend(id: ConvID.second)
        let runner = ConversationRunner { _, _ in ConvFixture.output("send-ack") }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    @Test func givenReceiptForAnotherWitnessConversation_whenSent_thenUncertainAsMismatch() async throws {
        // given: the fixture's conversation is ...001; this request's witness names another conversation
        let witness = try convWitness(conversation: "00000000-0000-0000-0000-000000000002")
        let request = try ConversationDeliverySendRequest(requestID: ConvID.uuid(ConvID.message), witness: witness,
                                                          target: .task(taskID: ConvID.head), mode: .queue, text: "hi")
        let runner = ConversationRunner { _, _ in ConvFixture.output("send-ack") }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    @Test(arguments: ControlReceiptMutation.allCases)
    func givenControlReceiptWithBrokenIdentity_whenControlled_thenUncertainAsMismatch(mutation: ControlReceiptMutation) async throws {
        // given: SYNTHETIC mutation of the cancel-ack fixture
        var raw = try ConvFixture.result("cancel-ack")
        mutation.apply(&raw)
        let request = try convControl()
        let runner = ConversationRunner { _, _ in convResult(raw) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    @Test(arguments: WorkflowControlMutation.allCases)
    func givenWorkflowControlReceiptWithBrokenIdentity_whenControlled_thenUncertainAsMismatch(mutation: WorkflowControlMutation) async throws {
        // given: SYNTHETIC mutation of the workflow-cancel-ack fixture
        var raw = try ConvFixture.result("workflow-cancel-ack")
        mutation.apply(&raw)
        let request = try convControl(target: convWorkflowTarget)
        let runner = ConversationRunner { _, _ in convResult(raw) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    @Test func givenPromoteReceiptForCancelRequest_whenControlled_thenUncertainAsMismatch() async throws {
        // given: the promote-ack fixture answers operation promote_now with operation id ...0ca
        let request = try convControl(id: ConvID.promote, operation: .cancel)
        let runner = ConversationRunner { _, _ in ConvFixture.output("promote-ack") }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    // MARK: Workflow-shaped receipts for task requests

    @Test(arguments: ["workflow_run_id", "activation_id"])
    func givenWorkflowIdentityOnTaskSendReceipt_whenSent_thenUncertainAsMismatch(key: String) async throws {
        // given: SYNTHETIC; the send-ack fixture with one non-null workflow key added, every other identity matching
        var raw = try ConvFixture.result("send-ack")
        raw[key] = .string(key == "workflow_run_id" ? ConvID.run : ConvID.activation)
        // when
        let run = try await convRunSend { convResult(raw) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .receiptIdentityMismatch))
    }

    @Test func givenWorkflowSendAckFixture_whenAnsweringATaskRequest_thenUncertainDespiteMatchingIds() async throws {
        // given: the workflow-send-ack fixture shares message, task and conversation ids with a task request
        let request = try convSend(target: .task(taskID: ConvID.head))
        let runner = ConversationRunner { _, _ in ConvFixture.output("workflow-send-ack") }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    @Test(arguments: ["workflow_run_id", "activation_id"])
    func givenNullWorkflowIdentityOnTaskSendReceipt_whenSent_thenItIsStillAccepted(key: String) async throws {
        // given: SYNTHETIC; null means the receipt is not workflow-shaped
        var raw = try ConvFixture.result("send-ack")
        raw[key] = .null
        // when
        let run = try await convRunSend { convResult(raw) }
        // then
        #expect(run.outcome.isAccepted)
    }

    @Test(arguments: ["workflow_run_id", "activation_id"])
    func givenWorkflowIdentityOnTaskControlReceipt_whenControlled_thenUncertainAsMismatch(key: String) async throws {
        // given: SYNTHETIC; the cancel-ack fixture with one non-null workflow key added
        var raw = try ConvFixture.result("cancel-ack")
        raw[key] = .string(key == "workflow_run_id" ? ConvID.run : ConvID.activation)
        let request = try convControl()
        let runner = ConversationRunner { _, _ in convResult(raw) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    @Test func givenWorkflowCancelAckFixture_whenAnsweringATaskControl_thenUncertain() async throws {
        // given
        let request = try convControl(target: .task(taskID: ConvID.head))
        let runner = ConversationRunner { _, _ in ConvFixture.output("workflow-cancel-ack") }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome == .uncertain(request, cause: .receiptIdentityMismatch))
    }

    @Test(arguments: ["workflow_run_id", "activation_id"])
    func givenNullWorkflowIdentityOnTaskControlReceipt_whenControlled_thenItIsStillAccepted(key: String) async throws {
        // given: SYNTHETIC
        var raw = try ConvFixture.result("cancel-ack")
        raw[key] = .null
        let request = try convControl()
        let runner = ConversationRunner { _, _ in convResult(raw) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome.isAccepted)
    }
}
