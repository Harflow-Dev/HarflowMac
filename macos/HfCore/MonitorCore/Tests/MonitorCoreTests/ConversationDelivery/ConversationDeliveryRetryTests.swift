import Foundation
@testable import MonitorCore
import Testing

// MARK: - Scenario

/// SYNTHETIC non-accepted answers, each paired with the probe that precedes it.
enum NonAcceptedScenario: String, CaseIterable, Sendable {
    case commandTimeout, usageExitTwo, engineError, resultWithNonZeroExit, launchFailed, processFailure
    case oversizeOutput, identityMismatch, incompatibleAfterLaunch, incompatibleBeforeLaunch, missingCapability, probeTimeout

    var probe: ConversationRunner.Probe {
        switch self {
        case .incompatibleBeforeLaunch: { environment, _ in .success(conversationProbe(environment, productVersion: "0.1.0")) }
        case .missingCapability: { environment, _ in .success(conversationProbe(environment, capability: false)) }
        case .probeTimeout: { _, _ in .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true)) }
        default: { environment, _ in .success(conversationProbe(environment)) }
        }
    }

    var answer: ConvResult {
        switch self {
        case .commandTimeout: convRaw(exit: 0, timedOut: true)
        case .usageExitTwo: convError(code: "usage", message: "bad", exit: 2)
        case .engineError: convError(code: "request_expired")
        case .resultWithNonZeroExit: convResult(["contract": .string("conversation_delivery_v1")], exit: 1)
        case .launchFailed: .failure(.launchFailed(tool: "harflow-ctl", detail: "spawn"))
        case .processFailure: .failure(.notFound(tool: "harflow-ctl", searched: []))
        case .oversizeOutput: .success(ProcessOutput(exitCode: 0, stdout: Data(count: (1 << 20) + 1), stderr: ""))
        case .identityMismatch: convResult(["contract": .string("conversation_delivery_v1"), "message_id": .string("nope")])
        case .incompatibleAfterLaunch: convDocument(["result": .object([:]), "product_version": .string("0.1.0")], exit: 0)
        case .incompatibleBeforeLaunch, .missingCapability, .probeTimeout: convRaw(exit: 0)
        }
    }
}

// MARK: - ConversationDeliveryRetryTests

/// Retry evidence, no automatic retry, cancellation and legacy isolation. All answers are
/// SYNTHETIC unless a fixture is named.
struct ConversationDeliveryRetryTests {
    @Test(arguments: NonAcceptedScenario.allCases)
    func givenAnyNonAcceptedScenario_whenSent_thenTheIdenticalRequestAndBytesComeBack(scenario: NonAcceptedScenario) async throws {
        // given
        let request = try convSend(mode: .now)
        let runner = ConversationRunner(probe: scenario.probe) { _, _ in scenario.answer }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        let carried = try #require(outcome.carriedRequest)
        #expect(!outcome.isAccepted)
        #expect(carried == request)
        #expect(carried.body == request.body)
    }

    @Test(arguments: NonAcceptedScenario.allCases)
    func givenAnyNonAcceptedScenario_whenControlled_thenTheIdenticalRequestAndBytesComeBack(scenario: NonAcceptedScenario) async throws {
        // given
        let request = try convControl(operation: .promoteNow, target: convWorkflowTarget)
        let runner = ConversationRunner(probe: scenario.probe) { _, _ in scenario.answer }
        // when
        let outcome = await conversationClient(runner).conversationControl(request)
        // then
        let carried = try #require(outcome.carriedRequest)
        #expect(!outcome.isAccepted)
        #expect(carried == request)
        #expect(carried.body == request.body)
    }

    @Test(arguments: NonAcceptedScenario.allCases)
    func givenAnyScenario_whenSent_thenAtMostOneProbeAndOneLaunchHappen(scenario: NonAcceptedScenario) async throws {
        // given
        let request = try convSend()
        let runner = ConversationRunner(probe: scenario.probe) { _, _ in scenario.answer }
        // when
        _ = await conversationClient(runner).conversationSend(request)
        // then
        #expect(runner.probeCount == 1)
        #expect(runner.commandCalls.count <= 1)
    }

    @Test func givenTimeoutThenProbeFailure_whenRetried_thenSecondOutcomeCarriesTheSameRequestAndClaimsNothingAboutTheFirst() async throws {
        // given
        let request = try convSend()
        let runner = ConversationRunner(
            probe: { environment, index in
                index == 1 ? .success(conversationProbe(environment)) : .failure(.timedOut(tool: "harflow-ctl version-info", seconds: 10))
            },
            command: { _, _ in convRaw(exit: 0, timedOut: true) }
        )
        let client = conversationClient(runner)
        // when
        let first = await client.conversationSend(request)
        let second = await client.conversationSend(request)
        // then
        #expect(first == .uncertain(request, cause: .timedOut(seconds: 120)))
        #expect(second == .notDispatched(request, cause: .probeFailed(.timedOut(tool: "harflow-ctl version-info", seconds: 10))))
        #expect(runner.commandCalls.count == 1)
    }

    @Test func givenTimeoutThenRequestExpired_whenRetried_thenSecondIsAnEngineErrorWithTheSameRequest() async throws {
        // given
        let request = try convSend()
        let runner = ConversationRunner { _, index in
            index == 1 ? convRaw(exit: 0, timedOut: true) : ConvFixture.output("refusal-request-expired")
        }
        let client = conversationClient(runner)
        // when
        let first = await client.conversationSend(request)
        let second = await client.conversationSend(request)
        // then
        #expect(first == .uncertain(request, cause: .timedOut(seconds: 120)))
        #expect(second == .engineError(request, ConversationDeliveryEngineError(code: "request_expired", message: "request_expired", data: nil)))
    }

    @Test func givenExplicitRetry_whenSentAgain_thenRequestFilesCarryIdenticalBytes() async throws {
        // given
        let request = try convSend(mode: .now, target: convWorkflowTarget)
        let bodies = Collector<Data?>()
        let runner = ConversationRunner { arguments, index in
            bodies.add(snapshotRequestFile(arguments).body)
            return index == 1 ? convRaw(exit: 0, timedOut: true) : ConvFixture.output("send-ack")
        }
        let client = conversationClient(runner)
        // when
        _ = await client.conversationSend(request)
        let rehydrated = try ConversationDeliverySendRequest(requestID: request.requestID, witness: request.witness, target: request.target,
                                                             mode: request.mode, text: request.text)
        _ = await client.conversationSend(rehydrated)
        // then
        #expect(bodies.values.count == 2)
        #expect(bodies.values[0] == request.body)
        #expect(bodies.values[1] == request.body)
    }

    @Test func givenControlRetry_whenSentAgain_thenRequestFilesCarryIdenticalBytes() async throws {
        // given
        let request = try convControl(id: ConvID.promote, operation: .promoteNow)
        let bodies = Collector<Data?>()
        let runner = ConversationRunner { arguments, index in
            bodies.add(snapshotRequestFile(arguments).body)
            return index == 1 ? convRaw(exit: 1, stdout: "garbage") : ConvFixture.output("promote-ack")
        }
        let client = conversationClient(runner)
        // when
        let first = await client.conversationControl(request)
        let second = await client.conversationControl(request)
        // then
        #expect(bodies.values == [request.body, request.body])
        #expect(first.carriedRequest == request)
        #expect(second.isAccepted)
    }

    @Test(arguments: [NonAcceptedScenario.commandTimeout, .engineError, .processFailure, .oversizeOutput])
    func givenFailedLaunch_whenSent_thenThereIsNoAutomaticRetry(scenario: NonAcceptedScenario) async throws {
        // given
        let runner = ConversationRunner(probe: scenario.probe) { _, _ in scenario.answer }
        // when
        _ = try await conversationClient(runner).conversationSend(convSend())
        // then
        #expect(runner.commandCalls.count == 1)
        #expect(runner.allCalls.map(\.first) == ["version-info", "conversation-send"])
    }

    // MARK: Cancellation

    @Test func givenCallerCancelledAfterLaunch_whenReceiptArrives_thenTheAcceptedReceiptSurvives() async throws {
        // given: the runner cancels the calling task while the command is running
        let request = try convSend()
        let runner = ConversationRunner { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return ConvFixture.output("send-ack")
        }
        let client = conversationClient(runner)
        // when
        let outcome = await Task { await client.conversationSend(request) }.value
        // then
        #expect(outcome.isAccepted)
        #expect(runner.commandCalls.count == 1)
    }

    @Test func givenCallerCancelledAfterLaunch_whenControlReceiptArrives_thenTheAcceptedReceiptSurvives() async throws {
        // given
        let request = try convControl()
        let runner = ConversationRunner { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return ConvFixture.output("cancel-ack")
        }
        let client = conversationClient(runner)
        // when
        let outcome = await Task { await client.conversationControl(request) }.value
        // then
        #expect(outcome.isAccepted)
    }

    @Test func givenCallerCancelledBeforeAnything_whenSent_thenNotDispatchedAndNothingRuns() async throws {
        // given
        let request = try convSend()
        let runner = ConversationRunner { _, _ in Issue.record("must not launch"); return convRaw(exit: 0) }
        let client = conversationClient(runner)
        // when
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.conversationSend(request)
        }.value
        // then
        #expect(outcome == .notDispatched(request, cause: .cancelledBeforeLaunch))
        #expect(runner.allCalls.isEmpty)
    }

    @Test func givenOwnerGenerationChangedBeforeProbe_whenSent_thenNotDispatchedWithoutProbing() async throws {
        // given
        let request = try convSend()
        let runner = ConversationRunner { _, _ in Issue.record("must not launch"); return convRaw(exit: 0) }
        var client = conversationClient(runner)
        client.operationIsCurrent = { false }
        // when
        let outcome = await client.conversationSend(request)
        // then
        #expect(outcome == .notDispatched(request, cause: .cancelledBeforeLaunch))
        #expect(runner.allCalls.isEmpty)
    }

    @Test func givenOwnerGenerationChangedDuringProbe_whenSent_thenNotDispatchedAfterOnlyTheProbe() async throws {
        // given
        let request = try convSend()
        let checks = Collector<Int>()
        let runner = ConversationRunner { _, _ in Issue.record("must not launch"); return convRaw(exit: 0) }
        var client = conversationClient(runner)
        client.operationIsCurrent = {
            checks.add(1)
            return checks.values.count < 2
        }
        // when
        let outcome = await client.conversationSend(request)
        // then
        #expect(outcome == .notDispatched(request, cause: .cancelledBeforeLaunch))
        #expect(runner.allCalls == [["version-info", "--json"]])
    }

    // MARK: Legacy messaging

    @Test func givenLegacySend_whenCalled_thenItKeepsItsOwnArgvCapabilityAndNeedsNoRequestFile() async throws {
        // given: a runtime that offers messaging.v1 but not conversation-delivery.v1
        let runner = ConversationRunner(
            probe: { environment, _ in .success(conversationProbe(environment, capability: false, extraCapabilities: ["messaging.v1"])) },
            command: { _, _ in convResult(["status": .string("queued")]) }
        )
        let client = conversationClient(runner)
        // when
        let legacy = await client.send("task-1", text: "hi")
        let legacyNow = await client.sendNow("task-1", text: "now")
        let cancelled = await client.cancelMessage("task-1", messageID: "m-1")
        // then
        #expect(try legacy.get()["status"]?.stringValue == "queued")
        #expect(try legacyNow.get()["status"]?.stringValue == "queued")
        #expect(try cancelled.get()["status"]?.stringValue == "queued")
        #expect(runner.commandCalls == [
            ["send", "--delivery=queue", "--monitor", "--json", "--", "task-1", "hi"],
            ["send", "--delivery=now", "--monitor", "--json", "--", "task-1", "now"],
            ["cancel-message", "--monitor", "--json", "--", "task-1", "m-1"]
        ])
    }

    @Test func givenLegacySendWithoutMessagingCapability_whenCalled_thenConversationCapabilityDoesNotSubstituteForIt() async {
        // given
        let runner = ConversationRunner(
            probe: { environment, _ in .success(conversationProbe(environment)) },
            command: { _, _ in Issue.record("must not launch"); return convRaw(exit: 0) }
        )
        // when
        let result = await conversationClient(runner).send("task-1", text: "hi")
        // then
        guard case .failure(.unsupportedCommand(_, _, let detail)) = result else { Issue.record("expected unsupportedCommand, got \(result)"); return }
        #expect(detail == "Missing capability messaging.v1")
        #expect(runner.commandCalls.isEmpty)
    }
}
