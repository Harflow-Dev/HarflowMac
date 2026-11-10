import Foundation
@testable import MonitorCore
import Testing

typealias ConvSendOutcome = ConversationDeliveryOutcome<ConversationDeliverySendRequest, ConversationDeliverySendReceipt>
typealias ConvControlOutcome = ConversationDeliveryOutcome<ConversationDeliveryControlRequest, ConversationDeliveryControlReceipt>

/// Sends one default request through a runner that answers the command with `command`.
func convRunSend(
    probe: ConversationRunner.Probe? = nil, command: @escaping @Sendable () -> ConvResult
) async throws -> (request: ConversationDeliverySendRequest, outcome: ConvSendOutcome, runner: ConversationRunner) {
    let request = try convSend()
    let runner = if let probe {
        ConversationRunner(probe: probe) { _, _ in command() }
    } else {
        ConversationRunner { _, _ in command() }
    }
    return (request, await conversationClient(runner).conversationSend(request), runner)
}

// MARK: - ConversationDeliveryOutcomeTests

/// Outcome classification, one test per row of the plan's table. Rows that use a fixture say so;
/// every other row is a SYNTHETIC runner answer, not engine output.
struct ConversationDeliveryOutcomeTests {
    @Test func givenResultAndUnknownCollision_whenClassified_thenUncertainBeforeReceiptDecode() {
        // given
        let client = conversationClient(ConversationRunner { _, _ in convRaw(exit: 0) })
        let answer = convDocument(["result": .object([:]), "unknown": .object(["message": .string("maybe")])], exit: 0)
        // when
        let outcome: ConversationDeliveryOutcome<String, String> = client.classifyConversationMutation(
            answer, command: "conversation-send", options: ["--monitor"], request: "request") { _ in
                Issue.record("colliding payload must not decode a receipt")
                return "accepted"
            }
        // then
        #expect(outcome == .uncertain("request", cause: .inconsistentEnvelope(exitCode: 0, detail: "multiple result/error/unknown payloads")))
    }

    private let parserText = "usage: harflow-ctl conversation-send [-h]\nharflow-ctl: error: unrecognized arguments: --bogus"

    // MARK: Accepted

    @Test func givenSendAckFixtureWithAdditiveFields_whenSent_thenAcceptedToleratesThem() async throws {
        // given: fixture plus a SYNTHETIC additive key
        var raw = try ConvFixture.result("send-ack")
        raw["future_field"] = .object(["x": .number(1)])
        // when
        let run = try await convRunSend { convResult(raw) }
        // then
        guard case .accepted(let receipt) = run.outcome else { Issue.record("expected accepted, got \(run.outcome)"); return }
        #expect(receipt.raw["future_field"] != nil)
    }

    @Test(arguments: ["delivery", "sequence", "status", "resolved_task_id"])
    func givenConditionalFieldAbsent_whenSent_thenReceiptIsStillAccepted(key: String) async throws {
        // given: fixture with one conditional key removed (SYNTHETIC mutation)
        var raw = try ConvFixture.result("send-ack")
        raw[key] = nil
        // when
        let run = try await convRunSend { convResult(raw) }
        // then
        #expect(run.outcome.isAccepted)
    }

    @Test func givenResolvedTaskDiffersFromTarget_whenSent_thenHeadTaskIsNotComparedAndReceiptIsAccepted() async throws {
        // given: SYNTHETIC; the resolved task is the head task and may differ from the target
        var raw = try ConvFixture.result("send-ack")
        raw["resolved_task_id"] = .string("some-head-task")
        // when
        let run = try await convRunSend { convResult(raw) }
        // then
        guard case .accepted(let receipt) = run.outcome else { Issue.record("expected accepted, got \(run.outcome)"); return }
        #expect(receipt.resolvedTaskID == "some-head-task")
    }

    @Test func givenControlTargetDiffersFromHeadTask_whenControlled_thenReceiptIsAccepted() async throws {
        // given: SYNTHETIC; control.target_task_id is the head task
        var raw = try ConvFixture.result("cancel-ack")
        var control = try #require(raw["control"]?.objectValue)
        control["target_task_id"] = .string("some-head-task")
        raw["control"] = .object(control)
        raw["resolved_task_id"] = .string("some-head-task")
        let request = try convControl()
        let runner = ConversationRunner { _, _ in convResult(raw) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        guard case .accepted(let receipt) = outcome else { Issue.record("expected accepted, got \(outcome)"); return }
        #expect(receipt.targetTaskID == "some-head-task")
    }

    // MARK: Usage and parser rows

    @Test func givenExitOneUsageEnvelopeWithParserText_whenSent_thenEngineErrorKeepsTheRequest() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convError(code: "usage", message: parserText, exit: 1) }
        // then
        #expect(run.outcome == .engineError(run.request, ConversationDeliveryEngineError(code: "usage", message: parserText, data: nil)))
    }

    @Test func givenExitTwoUsageEnvelope_whenSent_thenNotDispatchedAsUsageRejected() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convError(code: "usage", message: "bad usage", exit: 2) }
        // then
        #expect(run.outcome == .notDispatched(run.request, cause: .usageRejected(detail: "bad usage")))
    }

    @Test func givenExitTwoUsageEnvelope_whenControlled_thenNotDispatchedAsUsageRejected() async throws {
        // given: SYNTHETIC
        let request = try convControl()
        let runner = ConversationRunner { _, _ in convError(code: "usage", message: "bad usage", exit: 2) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome == .notDispatched(request, cause: .usageRejected(detail: "bad usage")))
    }

    @Test(arguments: ["harflow-ctl: error: argument command: invalid choice: 'conversation-send'", "usage: harflow-ctl [-h]",
                      "harflow-ctl: error: unrecognized arguments: --monitor", "error: the following arguments are required: file",
                      "usage: harflow-ctl conversation-send [-h]\nKeyboardInterrupt"])
    func givenExitTwoParserTextWithoutDocument_whenSent_thenUncertainAndTheRequestIsKept(stderr: String) async throws {
        // given: SYNTHETIC; parser-looking stderr is not proof of non-dispatch. The last sample stands in for a
        // SIGINT-like termination after admission that the runner also reports as exit 2.
        let run = try await convRunSend { convRaw(exit: 2, stderr: stderr) }
        // then
        guard case .uncertain(let request, let cause) = run.outcome else { Issue.record("expected uncertain, got \(run.outcome)"); return }
        #expect(request == run.request)
        if case .unreadableOutput(let exitCode, let detail) = cause {
            #expect(exitCode == 2)
            #expect(detail == stderr)
        } else {
            Issue.record("expected unreadableOutput, got \(cause)")
        }
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test(arguments: ["harflow-ctl: error: argument command: invalid choice: 'conversation-control'", "usage: harflow-ctl [-h]"])
    func givenExitTwoParserTextWithoutDocument_whenControlled_thenUncertainAndTheRequestIsKept(stderr: String) async throws {
        // given: SYNTHETIC
        let request = try convControl()
        let runner = ConversationRunner { _, _ in convRaw(exit: 2, stderr: stderr) }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        #expect(outcome == .uncertain(request, cause: .unreadableOutput(exitCode: 2, stderr: stderr)))
    }

    @Test func givenExitOneUsageTextWithoutDocument_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC; text at exit 1 with no envelope is unreadable output, never an engine error
        let run = try await convRunSend { convRaw(exit: 1, stderr: "usage: harflow-ctl [-h]") }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .unreadableOutput(exitCode: 1, stderr: "usage: harflow-ctl [-h]")))
    }

    @Test func givenExitTwoOtherTextWithoutDocument_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC; exit 2 alone is not proof of a parser rejection
        let run = try await convRunSend { convRaw(exit: 2, stderr: "Traceback (most recent call last)") }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .unreadableOutput(exitCode: 2, stderr: "Traceback (most recent call last)")))
    }

    @Test func givenExitOneParserTextWithoutDocument_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC; parser-looking text at exit 1 is never proof
        let run = try await convRunSend { convRaw(exit: 1, stderr: parserText) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .unreadableOutput(exitCode: 1, stderr: parserText)))
    }

    // MARK: Envelope and exit consistency rows

    @Test(arguments: [Int32(0), 2, 3, 127, 255])
    func givenErrorEnvelopeAtAnyExitOtherThanOne_whenSent_thenUncertain(exit: Int32) async throws {
        // given: SYNTHETIC; a non-usage code at exit 2 and any code elsewhere
        let run = try await convRunSend { convError(code: "request_expired", exit: exit) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: exit, detail: "error with exit other than 1")))
    }

    @Test(arguments: [Int32(0), 1, 3])
    func givenUsageEnvelopeAtNonUsageExit_whenSent_thenItIsNotTreatedAsParserRejection(exit: Int32) async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convError(code: "usage", message: parserText, exit: exit) }
        // then
        if exit == 1 {
            #expect(run.outcome == .engineError(run.request, ConversationDeliveryEngineError(code: "usage", message: parserText, data: nil)))
        } else {
            #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: exit, detail: "error with exit other than 1")))
        }
    }

    @Test(arguments: [Int32(1), 2, 3])
    func givenResultWithNonZeroExit_whenSent_thenUncertainEvenWithAMatchingReceipt(exit: Int32) async throws {
        // given: SYNTHETIC exit on top of the send-ack fixture's receipt
        let raw = try ConvFixture.result("send-ack")
        let run = try await convRunSend { convResult(raw, exit: exit) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: exit, detail: "result with non-zero exit")))
    }

    @Test func givenErrorWithExitZero_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convError(code: "queue_full", exit: 0) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: 0, detail: "error with exit other than 1")))
    }

    @Test func givenBothResultAndError_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC
        let raw = try ConvFixture.result("send-ack")
        let run = try await convRunSend {
            convDocument(["result": .object(raw), "error": .object(["code": .string("x"), "message": .string("x")])], exit: 0)
        }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: 0, detail: "both result and error")))
    }

    @Test func givenNeitherResultNorError_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convDocument([:], exit: 0) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: 0, detail: "neither result nor error")))
    }

    @Test func givenMalformedErrorObject_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convDocument(["error": .string("boom")], exit: 1) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: 1, detail: "malformed error object")))
    }

    @Test func givenErrorWithoutCode_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convDocument(["error": .object(["message": .string("no code")])], exit: 1) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: 1, detail: "malformed error object")))
    }

    @Test func givenNonObjectResult_whenSent_thenReceiptIdentityMismatch() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convDocument(["result": .string("ok")], exit: 0) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .receiptIdentityMismatch))
    }

    // MARK: Engine errors

    @Test func givenErrorDataWithPublishedFact_whenSent_thenDataIsRetainedVerbatim() async throws {
        // given: SYNTHETIC structured refusal; the engine reports a post-publication failure with this shape
        let data: [String: JSONValue] = ["published": .bool(true), "detail": .object(["step": .string("schedule")])]
        let run = try await convRunSend { convError(code: "delivery_failed", message: "after commit", data: .object(data), exit: 1) }
        // then
        #expect(run.outcome == .engineError(run.request, ConversationDeliveryEngineError(code: "delivery_failed", message: "after commit", data: data)))
    }

    @Test(arguments: [JSONValue.null, nil])
    func givenNullOrAbsentErrorData_whenSent_thenEngineErrorHasNoData(data: JSONValue?) async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convError(code: "queue_full", data: data) }
        // then
        #expect(run.outcome == .engineError(run.request, ConversationDeliveryEngineError(code: "queue_full", message: "queue_full", data: nil)))
    }

    @Test func givenNonObjectErrorData_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convError(code: "queue_full", data: .string("raw")) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .inconsistentEnvelope(exitCode: 1, detail: "malformed error data")))
    }

    @Test func givenEngineErrorAfterAdmission_whenSent_thenItIsOnlyAnEngineErrorWithNoNonAdmissionClaim() async throws {
        // given: SYNTHETIC; the engine prints the same envelope after a durable write
        let run = try await convRunSend { convError(code: "internal_error", message: "drain failed", data: .object(["published": .bool(true)])) }
        // then
        guard case .engineError(let request, let error) = run.outcome else { Issue.record("expected engineError, got \(run.outcome)"); return }
        #expect(request == run.request)
        #expect(error.code == "internal_error")
        #expect(error.data?["published"] == .bool(true))
    }

    // MARK: Compatibility rows

    @Test(arguments: ["0.1.0", "1.0.0"])
    func givenProbeOnAnotherReleaseLine_whenSent_thenNotDispatchedAndNothingLaunches(version: String) async throws {
        // given: SYNTHETIC probe
        let run = try await convRunSend(
            probe: { environment, _ in .success(conversationProbe(environment, productVersion: version)) },
            command: { Issue.record("must not launch"); return convRaw(exit: 0) }
        )
        // then
        guard case .notDispatched(let request, .probeFailed(.refused(let code, _))) = run.outcome else {
            Issue.record("expected probeFailed, got \(run.outcome)")
            return
        }
        #expect(request == run.request)
        #expect(code == "incompatible_runtime")
        #expect(run.runner.commandCalls.isEmpty)
    }

    @Test(arguments: ["0.1.0", "1.0.0", "0.0.11-beta"])
    func givenWrongProductVersionAfterLaunch_whenSent_thenUncertainAsIncompatibleEnvelope(version: String) async throws {
        // given: SYNTHETIC; same refusal code as the pre-launch case, different phase
        let raw = try ConvFixture.result("send-ack")
        let run = try await convRunSend { convDocument(["result": .object(raw), "product_version": .string(version)], exit: 0) }
        // then
        guard case .uncertain(let request, .incompatibleEnvelope(.refused(let code, _))) = run.outcome else {
            Issue.record("expected incompatibleEnvelope, got \(run.outcome)")
            return
        }
        #expect(request == run.request)
        #expect(code == "incompatible_runtime")
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test(arguments: [
        #"{"product":"other","format":"harflow.ctl","v":1,"product_version":"0.0.11","result":{}}"#,
        #"{"product":"harflow","format":"harflow.setup","v":1,"product_version":"0.0.11","result":{}}"#
    ])
    func givenForeignEnvelopeAfterLaunch_whenSent_thenUncertainAsIncompatibleEnvelope(document: String) async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convRaw(exit: 0, stdout: document) }
        // then
        guard case .uncertain(_, .incompatibleEnvelope(.refused(let code, _))) = run.outcome else {
            Issue.record("expected incompatibleEnvelope, got \(run.outcome)")
            return
        }
        #expect(code == "incompatible_runtime")
    }

    @Test func givenUnsupportedContractVersionAfterLaunch_whenSent_thenUncertainAsIncompatibleEnvelope() async throws {
        // given: SYNTHETIC
        let document = #"{"product":"harflow","format":"harflow.ctl","v":99,"product_version":"0.0.11","result":{}}"#
        let run = try await convRunSend { convRaw(exit: 0, stdout: document) }
        // then
        guard case .uncertain(_, .incompatibleEnvelope(.unsupportedVersion)) = run.outcome else {
            Issue.record("expected unsupportedVersion, got \(run.outcome)")
            return
        }
    }

    // MARK: Timeouts and runner failures

    @Test(arguments: ["timed-out-output", "runner-failure"])
    func givenProbeTimeout_whenSent_thenNotDispatchedAndNothingLaunches(mode: String) async throws {
        // given: SYNTHETIC
        let run = try await convRunSend(
            probe: { _, _ in
                mode == "runner-failure"
                    ? .failure(.timedOut(tool: "harflow-ctl version-info", seconds: 10))
                    : .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
            },
            command: { Issue.record("must not launch"); return convRaw(exit: 0) }
        )
        // then
        #expect(run.outcome == .notDispatched(run.request, cause: .probeFailed(.timedOut(tool: "harflow-ctl version-info", seconds: 10))))
        #expect(run.runner.commandCalls.isEmpty)
    }

    @Test func givenCommandTimeout_whenSent_thenUncertainAndExactlyOneLaunch() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convRaw(exit: 0, timedOut: true) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .timedOut(seconds: 120)))
        #expect(run.runner.commandCalls.count == 1)
        #expect(run.runner.probeCount == 1)
    }

    @Test func givenRunnerReportsCommandTimeout_whenSent_thenUncertainAsProcessFailure() async throws {
        // given: SYNTHETIC
        let failure = ToolError.timedOut(tool: "harflow-ctl", seconds: 120)
        let run = try await convRunSend { .failure(failure) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .processFailure(failure)))
    }

    @Test func givenLaunchFailure_whenSent_thenNotDispatched() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { .failure(.launchFailed(tool: "harflow-ctl", detail: "posix_spawn failed")) }
        // then
        #expect(run.outcome == .notDispatched(run.request, cause: .launchFailed(tool: "harflow-ctl", detail: "posix_spawn failed")))
    }

    @Test func givenProbeLaunchFailure_whenSent_thenNotDispatchedAsProbeFailure() async throws {
        // given: SYNTHETIC
        let failure = ToolError.launchFailed(tool: "harflow-ctl", detail: "no such file")
        let run = try await convRunSend(probe: { _, _ in .failure(failure) }, command: { convRaw(exit: 0) })
        // then
        #expect(run.outcome == .notDispatched(run.request, cause: .probeFailed(failure)))
        #expect(run.runner.commandCalls.isEmpty)
    }

    @Test(arguments: [
        ToolError.notFound(tool: "harflow-ctl", searched: ["/x"]),
        .unreadable(tool: "harflow-ctl", exitCode: 9, stderr: "x"),
        .unknownOutcome(message: "maybe"),
        .refused(code: "something", message: "else"),
        .unsupportedCommand(tool: "harflow-ctl", command: "conversation-send", detail: "d")
    ])
    func givenOtherRunnerFailure_whenSent_thenUncertainAsProcessFailure(failure: ToolError) async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { .failure(failure) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .processFailure(failure)))
    }

    @Test func givenUnreadableStdoutAtExitZero_whenSent_thenUncertain() async throws {
        // given: SYNTHETIC
        let run = try await convRunSend { convRaw(exit: 0, stdout: "plain text", stderr: "warn") }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .unreadableOutput(exitCode: 0, stderr: "warn")))
    }

    // MARK: Output cap

    @Test func givenStdoutOverOneMiB_whenSent_thenUncertainEvenIfItIsAValidReceipt() async throws {
        // given: the send-ack fixture padded past the cap with trailing spaces (SYNTHETIC padding)
        let cap = 1 << 20
        var padded = try ConvFixture.data(ConvFixture.file("send-ack"))
        padded.append(Data(repeating: 0x20, count: cap + 1 - padded.count))
        let output = ProcessOutput(exitCode: 0, stdout: padded, stderr: "")
        // when
        let run = try await convRunSend { .success(output) }
        // then
        #expect(run.outcome == .uncertain(run.request, cause: .outputTooLarge(bytes: cap + 1)))
    }

    @Test func givenStdoutExactlyOneMiB_whenSent_thenTheCapIsNotExceeded() async throws {
        // given: SYNTHETIC padding to exactly the cap
        let cap = 1 << 20
        var padded = try ConvFixture.data(ConvFixture.file("send-ack"))
        padded.append(Data(repeating: 0x20, count: cap - padded.count))
        let output = ProcessOutput(exitCode: 0, stdout: padded, stderr: "")
        // when
        let run = try await convRunSend { .success(output) }
        // then
        #expect(padded.count == cap)
        #expect(run.outcome.isAccepted)
    }
}
