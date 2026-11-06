import Foundation
@testable import MonitorCore
import Testing

// MARK: - ConversationDeliveryRequestTests

/// Local request building. All cases are synthetic: no engine and no fixture is involved.
struct ConversationDeliveryRequestTests {
    private let witnessKeys: Set = ["conversation_id", "head_task_id", "generation", "turn_id", "ledger_epoch"]

    @Test func givenTaskSend_whenRendered_thenKeySetsAreExactlyTheClosedContract() throws {
        // given / when
        let body = try decodedBody(convSend().body)
        // then
        #expect(Set(body.keys) == ["contract", "request_id", "delivery", "text", "target", "expected"])
        #expect(body["contract"]?.stringValue == "conversation_delivery_v1")
        #expect(body["delivery"]?.stringValue == "queue")
        #expect(Set(body["target"]?.objectValue?.keys ?? [:].keys) == ["kind", "task_id"])
        #expect(body["target"]?.objectValue?["kind"]?.stringValue == "task")
        #expect(Set(body["expected"]?.objectValue?.keys ?? [:].keys) == witnessKeys)
    }

    @Test func givenWorkflowSend_whenRendered_thenTargetCarriesRunActivationAndTask() throws {
        // given / when
        let target = try #require(decodedBody(convSend(mode: .now, target: convWorkflowTarget).body)["target"]?.objectValue)
        // then
        #expect(Set(target.keys) == ["kind", "workflow_run_id", "activation_id", "task_id"])
        #expect(target["kind"]?.stringValue == "workflow_activation")
        #expect(target["workflow_run_id"]?.stringValue == ConvID.run)
        #expect(target["activation_id"]?.stringValue == ConvID.activation)
        #expect(target["task_id"]?.stringValue == ConvID.head)
    }

    @Test(arguments: [ConversationDeliveryMode.queue, .now])
    func givenMode_whenRendered_thenDeliveryIsItsRawValue(mode: ConversationDeliveryMode) throws {
        // given / when
        let body = try decodedBody(convSend(mode: mode).body)
        // then
        #expect(body["delivery"]?.stringValue == mode.rawValue)
    }

    @Test(arguments: [ConversationDeliveryControlOperation.cancel, .promoteNow])
    func givenControl_whenRendered_thenKeySetsAreExactlyTheClosedContract(operation: ConversationDeliveryControlOperation) throws {
        // given / when
        let body = try decodedBody(convControl(operation: operation).body)
        // then
        #expect(Set(body.keys) == ["contract", "request_id", "operation", "target", "expected", "message_request_id"])
        #expect(body["operation"]?.stringValue == operation.rawValue)
        #expect(body["request_id"]?.stringValue == ConvID.cancel)
        #expect(body["message_request_id"]?.stringValue == ConvID.message)
        #expect(Set(body["expected"]?.objectValue?.keys ?? [:].keys) == witnessKeys)
    }

    @Test func givenUppercaseUUID_whenRendered_thenWireTextIsLowercaseCanonical() throws {
        // given
        let upper = try #require(UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789"))
        let request = try ConversationDeliverySendRequest(requestID: upper, witness: convWitness(), target: .task(taskID: ConvID.head),
                                                          mode: .queue, text: "hi")
        let control = try ConversationDeliveryControlRequest(requestID: upper, operation: .cancel, messageRequestID: upper,
                                                             witness: convWitness(), target: .task(taskID: ConvID.head))
        // when
        let sendBody = try decodedBody(request.body)
        let controlBody = try decodedBody(control.body)
        // then
        #expect(request.requestIDText == "abcdef01-2345-6789-abcd-ef0123456789")
        #expect(sendBody["request_id"]?.stringValue == "abcdef01-2345-6789-abcd-ef0123456789")
        #expect(controlBody["request_id"]?.stringValue == "abcdef01-2345-6789-abcd-ef0123456789")
        #expect(controlBody["message_request_id"]?.stringValue == "abcdef01-2345-6789-abcd-ef0123456789")
        #expect(control.messageRequestIDText == "abcdef01-2345-6789-abcd-ef0123456789")
    }

    @Test func givenCounters_whenRendered_thenTheyAreBareIntegersIncludingTheLargestExactValue() throws {
        // given
        let large = 999_999_999_999_999
        let witness = try ConversationDeliveryWitness(conversationID: ConvID.conversation, headTaskID: ConvID.head, generation: 7,
                                                      turnID: ConvID.turn, ledgerEpoch: large)
        let request = try ConversationDeliverySendRequest(requestID: ConvID.uuid(ConvID.message), witness: witness,
                                                          target: .task(taskID: ConvID.head), mode: .queue, text: "hi")
        // when
        let text = try #require(String(data: request.body, encoding: .utf8))
        // then
        #expect(text.contains("\"generation\":7"))
        #expect(!text.contains("7.0"))
        #expect(text.contains("\"ledger_epoch\":999999999999999"))
        #expect(try decodedBody(request.body)["expected"]?.objectValue?["ledger_epoch"]?.wireIntegerValue == large)
    }

    @Test(arguments: ["Keep  two spaces.\nSecond line\n", "trailing newline\n", "\ttabbed  text ", "caf\u{00E9} \u{1F642}", "a/b \"quoted\" \\ back",
                      "\u{00A0}nbsp"])
    func givenText_whenRendered_thenItSurvivesByteForByteAndIsNeverNormalized(text: String) throws {
        // given / when
        let request = try convSend(text: text)
        let body = try decodedBody(request.body)
        // then
        #expect(request.text == text)
        #expect(body["text"]?.stringValue == text)
        #expect(body["text"]?.stringValue?.utf8.count == text.utf8.count)
    }

    @Test func givenDecomposedAndComposedText_whenRendered_thenUTF8BytesAreExactAndNeverNormalized() throws {
        // given: Swift String equality treats these as equal, so only byte comparison can tell them apart
        let decomposed = "cafe\u{0301}"
        let composed = "caf\u{00E9}"
        let decomposedBytes: [UInt8] = [0x63, 0x61, 0x66, 0x65, 0xCC, 0x81]
        let composedBytes: [UInt8] = [0x63, 0x61, 0x66, 0xC3, 0xA9]
        // when
        let decomposedRequest = try convSend(text: decomposed)
        let composedRequest = try convSend(text: composed)
        let decomposedParsed = try #require(decodedBody(decomposedRequest.body)["text"]?.stringValue)
        let composedParsed = try #require(decodedBody(composedRequest.body)["text"]?.stringValue)
        // then: stored text, parsed text and the rendered file bytes
        #expect(Array(decomposedRequest.text.utf8) == decomposedBytes)
        #expect(Array(decomposedParsed.utf8) == decomposedBytes)
        #expect(Array(composedRequest.text.utf8) == composedBytes)
        #expect(Array(composedParsed.utf8) == composedBytes)
        #expect(decomposedRequest.body.range(of: Data(decomposedBytes)) != nil)
        #expect(decomposedRequest.body.range(of: Data([0xC3, 0xA9])) == nil)
        #expect(composedRequest.body.range(of: Data(composedBytes)) != nil)
        #expect(composedRequest.body.range(of: Data([0xCC, 0x81])) == nil)
        #expect(decomposedRequest.body != composedRequest.body)
    }

    @Test func givenSlashInText_whenRendered_thenItIsNotEscaped() throws {
        // given / when
        let request = try convSend(text: "a/b")
        // then
        #expect(String(data: request.body, encoding: .utf8)?.contains("\"a/b\"") == true)
    }

    @Test(arguments: ["", " ", "   ", "\n", "\t\r\n", "\u{0B}\u{0C}"])
    func givenEmptyOrAsciiWhitespaceText_whenBuilt_thenItIsRefusedAsBlank(text: String) {
        // given / when / then
        #expect(throws: ConversationDeliveryRequestError.blankText) { try convSend(text: text) }
    }

    @Test func givenNonAsciiWhitespaceText_whenBuilt_thenItIsLeftToTheEngine() throws {
        // given / when
        let request = try convSend(text: "\u{00A0}\u{2003}")
        // then
        #expect(request.text == "\u{00A0}\u{2003}")
    }

    @Test(arguments: [1, 32767, 32768])
    func givenTextUpToThirtyTwoKiB_whenBuilt_thenItIsAccepted(count: Int) throws {
        // given / when
        let request = try convSend(text: String(repeating: "a", count: count))
        // then
        #expect(request.text.utf8.count == count)
        #expect(request.body.count <= 65536)
    }

    @Test(arguments: [32769, 40000])
    func givenTextOverThirtyTwoKiB_whenBuilt_thenItIsRefusedWithItsByteCount(count: Int) {
        // given / when / then
        #expect(throws: ConversationDeliveryRequestError.textTooLarge(bytes: count)) {
            try convSend(text: String(repeating: "a", count: count))
        }
    }

    @Test func givenMultibyteText_whenMeasured_thenTheLimitCountsUTF8BytesNotCharacters() throws {
        // given
        let atLimit = String(repeating: "\u{00E9}", count: 16384)
        let overLimit = String(repeating: "\u{20AC}", count: 10923)
        // when
        let accepted = try convSend(text: atLimit)
        // then
        #expect(accepted.text.utf8.count == 32768)
        #expect(throws: ConversationDeliveryRequestError.textTooLarge(bytes: 32769)) { try convSend(text: overLimit) }
    }

    @Test func givenValidTextThatEscapesPastSixtyFourKiB_whenBuilt_thenRenderedSizeIsRefused() throws {
        // given: 32 KiB of control characters is valid text, but each escapes to six bytes
        let text = String(repeating: "\u{0001}", count: 32768)
        // when
        let error = #expect(throws: ConversationDeliveryRequestError.self) { try convSend(text: text) }
        // then
        guard case .requestTooLarge(let bytes)? = error else { Issue.record("expected requestTooLarge, got \(String(describing: error))"); return }
        #expect(bytes > 65536)
        #expect(text.utf8.count == 32768)
    }

    @Test func givenRenderedBodyAtAndOverSixtyFourKiB_whenBuilt_thenTheBoundaryIsExact() throws {
        // given: quotes escape to two bytes, so the body size is tuned byte by byte with a plain filler
        let base = try convSend(text: "a").body.count
        let quotes = (65536 - (base - 1)) / 2
        let filler = 65536 - (base - 1) - quotes * 2
        let text = String(repeating: "\"", count: quotes) + String(repeating: "a", count: filler)
        // when
        let atLimit = try convSend(text: text)
        // then
        #expect(text.utf8.count <= 32768)
        #expect(atLimit.body.count == 65536)
        #expect(throws: ConversationDeliveryRequestError.requestTooLarge(bytes: 65537)) { try convSend(text: text + "a") }
    }

    @Test(arguments: ["", "has\u{1F}control", "line\nbreak", String(repeating: "x", count: 257), String(repeating: "\u{00E9}", count: 129)])
    func givenInvalidIdentifier_whenBuiltAsHeadTask_thenWitnessIsRefused(identifier: String) {
        // given / when / then
        #expect(throws: ConversationDeliveryRequestError.invalidIdentifier(field: "head_task_id")) {
            try ConversationDeliveryWitness(conversationID: ConvID.conversation, headTaskID: identifier, generation: 0,
                                            turnID: ConvID.turn, ledgerEpoch: 0)
        }
    }

    @Test(arguments: ["a", "with space", String(repeating: "x", count: 256), String(repeating: "\u{00E9}", count: 128), "\u{1F642}"])
    func givenValidIdentifier_whenBuiltAsTurn_thenWitnessIsAccepted(identifier: String) throws {
        // given / when
        let witness = try ConversationDeliveryWitness(conversationID: ConvID.conversation, headTaskID: identifier, generation: 0,
                                                      turnID: identifier, ledgerEpoch: 0)
        // then
        #expect(witness.turnID == identifier)
    }

    @Test(arguments: ["", "not-a-uuid", "00000000000000000000000000000001", "00000000-0000-0000-0000-00000000000A",
                      "{00000000-0000-0000-0000-000000000001}"])
    func givenNonCanonicalConversationID_whenBuilt_thenWitnessIsRefused(conversation: String) {
        // given / when / then
        #expect(throws: ConversationDeliveryRequestError.invalidUUID(field: "conversation_id")) {
            try convWitness(conversation: conversation)
        }
    }

    @Test func givenInvalidTurnID_whenBuilt_thenWitnessIsRefused() {
        // given / when / then
        #expect(throws: ConversationDeliveryRequestError.invalidIdentifier(field: "turn_id")) {
            try ConversationDeliveryWitness(conversationID: ConvID.conversation, headTaskID: ConvID.head, generation: 0,
                                            turnID: "", ledgerEpoch: 0)
        }
    }

    @Test(arguments: [-1, 1_000_000_000_000_000, Int.max])
    func givenOutOfRangeCounters_whenBuilt_thenWitnessIsRefusedPerField(value: Int) {
        // given / when / then
        #expect(throws: ConversationDeliveryRequestError.invalidCounter(field: "generation")) {
            try convWitness(generation: value)
        }
        #expect(throws: ConversationDeliveryRequestError.invalidCounter(field: "ledger_epoch")) {
            try convWitness(epoch: value)
        }
    }

    @Test func givenBoundaryCounters_whenBuilt_thenZeroAndLargestAreAccepted() throws {
        // given / when
        let zero = try convWitness(generation: 0, epoch: 0)
        let large = try convWitness(generation: 999_999_999_999_999, epoch: 999_999_999_999_999)
        // then
        #expect(zero.generation == 0)
        #expect(large.ledgerEpoch == 999_999_999_999_999)
    }

    @Test func givenInvalidTargetIdentifiers_whenBuilt_thenSendAndControlAreRefusedPerField() {
        // given
        let badTask = ConversationDeliveryTarget.task(taskID: "")
        let badRun = ConversationDeliveryTarget.workflowActivation(workflowRunID: "", activationID: ConvID.activation, taskID: ConvID.head)
        let badActivation = ConversationDeliveryTarget.workflowActivation(workflowRunID: ConvID.run, activationID: "a\nb", taskID: ConvID.head)
        let badWorkflowTask = ConversationDeliveryTarget.workflowActivation(workflowRunID: ConvID.run, activationID: ConvID.activation,
                                                                            taskID: String(repeating: "x", count: 257))
        // when / then
        #expect(throws: ConversationDeliveryRequestError.invalidIdentifier(field: "target.task_id")) { try convSend(target: badTask) }
        #expect(throws: ConversationDeliveryRequestError.invalidIdentifier(field: "target.workflow_run_id")) { try convControl(target: badRun) }
        #expect(throws: ConversationDeliveryRequestError.invalidIdentifier(field: "target.activation_id")) { try convSend(target: badActivation) }
        #expect(throws: ConversationDeliveryRequestError.invalidIdentifier(field: "target.task_id")) { try convControl(target: badWorkflowTask) }
    }

    @Test func givenSameFields_whenRebuilt_thenValueAndBytesAreIdentical() throws {
        // given
        let first = try convSend(mode: .now, target: convWorkflowTarget)
        let control = try convControl(operation: .promoteNow)
        // when
        let rehydrated = try ConversationDeliverySendRequest(requestID: first.requestID, witness: first.witness, target: first.target,
                                                             mode: first.mode, text: first.text)
        let rehydratedControl = try ConversationDeliveryControlRequest(
            requestID: control.requestID, operation: control.operation, messageRequestID: control.messageRequestID,
            witness: control.witness, target: control.target
        )
        // then
        #expect(rehydrated == first)
        #expect(rehydrated.body == first.body)
        #expect(rehydratedControl == control)
        #expect(rehydratedControl.body == control.body)
    }

    @Test func givenAnyDifferingField_whenCompared_thenRequestsDiffer() throws {
        // given
        let base = try convSend()
        // when / then
        #expect(try convSend(id: ConvID.second) != base)
        #expect(try convSend(text: "other") != base)
        #expect(try convSend(mode: .now) != base)
        #expect(try convSend(target: convWorkflowTarget) != base)
    }
}
