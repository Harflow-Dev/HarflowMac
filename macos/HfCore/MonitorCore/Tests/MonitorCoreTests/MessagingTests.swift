import Foundation
@testable import MonitorCore
import Testing

// MARK: - MessagingTests

struct MessagingTests {
    private let taskID = String(repeating: "a", count: 32)

    private func fixture(_ name: String) throws -> [String: JSONValue] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "ContractsV1"))
        return try #require(JSONValue.parse(Data(contentsOf: url))?.objectValue)
    }

    @Test(arguments: [
        ("ctl-messaging-queued-ack", MessagingStatus.queued),
        ("ctl-messaging-now-checkpoint-required", .queued),
        ("ctl-messaging-now-continuation-refused", .queued),
        ("ctl-messaging-now-continuation-uncertain", .delivering),
        ("ctl-messaging-workflow-now-terminal", .undeliverable)
    ])
    func givenReceiptWithOptionalRefusal_whenDecoded_thenStatusRemainsAuthoritative(name: String, status: MessagingStatus) throws {
        // given
        let raw = try #require(fixture(name)["result"]?.objectValue)
        // when
        let receipt = try #require(MessagingSendReceipt(raw: raw))
        // then
        #expect(receipt.status == status)
        #expect(receipt.raw == raw)
    }

    @Test func givenCanonicalLegacyQueuedAndWorkflowFixtures_whenProjected_thenMessagesAreReadWithoutMutation() throws {
        // given
        let task = try #require(fixture("ctl-messaging-queued")["result"]?.objectValue)
        let run = try fixture("ctl-workflow-messages")
        // when / then
        #expect(MessagingSendReceipt(raw: task)?.status == .queued)
        let raw = try #require(run["result"]?.objectValue)
        let messages = QueuedMessageState.project(raw: raw, source: .workflowRun)
        #expect(messages.count == 2)
        #expect(messages.last?.state == .delivered && messages.last?.text == nil)
        #expect(messages.last?.deliveryTargetTaskID == "fixture-successor")
    }

    @Test func givenStandaloneDeliveredSource_whenProjected_thenSuccessorIsMetadataOnly() throws {
        // given
        let task = try #require(fixture("ctl-messaging-status-delivered")["task"]?.objectValue)
        // when
        let message = try #require(QueuedMessageState.project(raw: task, source: .standalone).first)
        // then
        #expect(message.state == .delivered)
        #expect(message.deliveryTargetTaskID == String(repeating: "b", count: 32))
        #expect(message.text == nil && message.isMetadataOnly && !message.canCancel)
    }

    @Test func givenWorkflowNode_whenProjected_thenDeliveryTaskComesFromRunLedger() throws {
        // given
        let task = try #require(fixture("ctl-messaging-status-workflow-node")["task"]?.objectValue)
        // when
        let message = try #require(QueuedMessageState.project(raw: task, source: .workflowNode(taskID: String(repeating: "e", count: 32))).first)
        // then
        #expect(message.state == .delivering)
        #expect(message.deliveryTargetTaskID == String(repeating: "e", count: 32))
        #expect(!message.canCancel)
    }

    @Test func givenStandaloneReasonAndWorkflowReason_whenProjected_thenOnlyStandaloneDeliveryIsUncertain() {
        // given — test-local synthetic future/legacy evidence, outside the canonical bundle.
        let raw: [String: JSONValue] = ["messages": .array([.object([
            "id": .string("synthetic"), "status": .string("delivering"), "reason": .string("inspection required")])])]
        // when / then
        #expect(QueuedMessageState.project(raw: raw, source: .standalone).first?.state == .uncertain)
        #expect(QueuedMessageState.project(raw: raw, source: .workflowNode(taskID: taskID)).first?.state == .delivering)
    }

    @Test func givenUnknownReceiptAndLedgerStatus_whenDecoded_thenEvidenceStaysReadOnly() throws {
        // given — test-local synthetic additive status.
        var raw = try #require(fixture("ctl-messaging-queued-ack")["result"]?.objectValue)
        raw["status"] = .string("future-status")
        let ledger: [String: JSONValue] = ["messages": .array([.object([
            "id": .string("synthetic"), "status": .string("future-status"), "text": .string("kept")])])]
        // when / then
        #expect(MessagingSendReceipt(raw: raw)?.status == .unknown("future-status"))
        let state = try #require(QueuedMessageState.project(raw: ledger, source: .standalone).first)
        #expect(state.state == .unknown("future-status") && !state.canCancel)
    }

    @Test func givenMalformedOptionalReceiptField_whenDecoded_thenReceiptCannotConfirmSubmission() throws {
        // given
        var raw = try #require(fixture("ctl-messaging-queued-ack")["result"]?.objectValue)
        raw["target_settled"] = .string("yes")
        // when / then
        #expect(MessagingSendReceipt(raw: raw) == nil)
    }

    @Test(arguments: ["queue", "now", "cancel"])
    func givenTimeoutAfterLaunch_whenSubmitting_thenOneMutationAndUnconfirmedOutcome(operation: String) async {
        // given
        let runner = compatibleRunner { _ in ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true) }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when / then
        if operation == "cancel" {
            guard case .unconfirmed = await client.cancelQueuedMessage(taskID, messageID: String(repeating: "b", count: 32)) else {
                Issue.record("Cancel timeout must stay unconfirmed"); return
            }
        } else {
            guard case .unconfirmed = await client.sendMessage(taskID, text: "same text", now: operation == "now") else {
                Issue.record("Send timeout must stay unconfirmed"); return
            }
        }
        #expect(runner.calls.count == 1)
    }

    @Test func givenCancelReceipt_whenDecoded_thenActualEngineStatusIsKept() throws {
        // given
        let raw = try #require(fixture("ctl-messaging-cancel")["result"]?.objectValue)
        // when / then
        #expect(MessagingCancelReceipt(raw: raw)?.status == .cancelled)
    }

    @Test func givenHandshakeWithoutMessaging_whenSending_thenUnsupportedWithoutMutation() async {
        // given
        let runner = RecordingRunner { call in
            let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
            let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.version-info"),
                "v": .number(1), "product_version": .string(HarflowVersion.current), "component": .string("engine"),
                "state_root": .string(root), "os": .string("darwin"), "architecture": .string("arm64"),
                "contracts": .object(["ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)])]),
                "capabilities": .array([.string("ctl.v1")])]
            return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when / then
        #expect(await client.sendMessage(taskID, text: "kept") == .messagingUnsupported)
        #expect(runner.calls.isEmpty)
    }

    @Test func givenSupersededRefusalWithoutStructuredSuccessor_whenSending_thenProseCannotAuthorizeRouting() async throws {
        // given
        let document = try fixture("ctl-messaging-send-error-superseded")
        let runner = compatibleRunner { _ in
            ProcessOutput(exitCode: 1, stdout: Data(JSONValue.object(document).rendered().utf8), stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let outcome = await client.sendMessage(taskID, text: "kept")
        // then
        guard case .refused(let refusal) = outcome else { Issue.record("Expected typed refusal"); return }
        #expect(refusal.kind == .superseded)
        #expect(refusal.successorTaskID == nil)
        #expect(refusal.message.contains(String(repeating: "b", count: 32)))
        #expect(runner.calls.count == 1)
    }

    @Test(arguments: [false, true])
    func givenEmptyRunIdentityWithoutTask_whenReceiptReturned_thenSubmissionStaysUnconfirmed(cancel: Bool) async {
        // given — malformed synthetic receipt outside the canonical bundle.
        let messageID = String(repeating: "b", count: 32)
        let raw: [String: JSONValue] = ["message_id": .string(messageID), "seq": .number(1),
            "status": .string(cancel ? "cancelled" : "queued"), "delivery": .string("queue"), "workflow_run_id": .string("")]
        let document: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"),
            "v": .number(1), "product_version": .string(HarflowVersion.current), "result": .object(raw)]
        let runner = compatibleRunner { _ in
            ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(document).rendered().utf8), stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when / then
        if cancel {
            #expect(await client.cancelQueuedMessage(taskID, messageID: messageID) == .unconfirmed(.receiptIdentityMismatch))
        } else {
            #expect(await client.sendMessage(taskID, text: "kept") == .unconfirmed(.receiptIdentityMismatch))
        }
        #expect(runner.calls.count == 1)
    }

}
