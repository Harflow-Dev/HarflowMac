import Foundation
@testable import MonitorCore
import Testing

// MARK: - ContinueClientTests

/// Base Continue uses synthetic transport answers and the already vendored launch fixtures.
struct ContinueClientTests {
    private let capabilities = [CtlCapability.taskContinue, CtlCapability.taskSuccessors]

    private func runner(_ answer: ConvResult) -> ConversationRunner {
        ConversationRunner(probe: { environment, _ in
            .success(conversationProbe(environment, capability: false,
                                       extraCapabilities: [CtlCapability.taskContinue, CtlCapability.taskSuccessors]))
        }, command: { _, _ in answer })
    }

    @Test func givenSelectedRuntime_whenContinued_thenProbeAndCommandUseSameIdentity() async {
        // given
        let runner = runner(LaunchFixture.output("continue-accepted"))
        let environment = ["HOME": "/fixture/home", "HARFLOW_STATE_ROOT": "/fixture/state"]
        let client = CtlClient(executable: "/fixture/selected/ctl", environment: environment, runner: runner)
        // when
        let outcome = await client.continueTask("prefix")
        // then
        #expect(outcome == .launched(taskID: "task-fixture"))
        #expect(runner.runtimeCalls.count == 2)
        for (executable, observed) in runner.runtimeCalls {
            #expect(executable == "/fixture/selected/ctl")
            #expect(observed == environment)
        }
    }

    @Test(arguments: ["-prefix", "task-prefix"])
    func givenSourcePrefix_whenContinued_thenUnchangedPositionalAndBoundedSingleLaunch(source: String) async {
        // given
        let runner = runner(LaunchFixture.output("continue-accepted"))
        // when
        let outcome = await conversationClient(runner).continueTask(source)
        // then: conversation-delivery is deliberately absent
        #expect(outcome == .launched(taskID: "task-fixture"))
        #expect(runner.allCalls == [["version-info", "--json"], ["continue", "--json", "--", source]])
        #expect(runner.commandTimeouts == [75])
    }

    @Test(arguments: [CtlCapability.taskContinue, CtlCapability.taskSuccessors])
    func givenOneMissingCapability_whenContinued_thenNoDispatch(missing: String) async {
        // given
        let offered = capabilities.filter { $0 != missing }
        let runner = ConversationRunner(probe: { environment, _ in
            .success(conversationProbe(environment, extraCapabilities: offered))
        }, command: { _, _ in Issue.record("must not dispatch"); return convRaw(exit: 0) })
        // when
        let outcome = await conversationClient(runner).continueTask("prefix")
        // then
        #expect(outcome == .notDispatched(.missingCapability(missing)))
        #expect(runner.probeCount == 1)
        #expect(runner.commandCalls.isEmpty)
    }

    @Test func givenAlternatingCapabilities_whenCalledTwice_thenProbesCannotCombine() async {
        // given
        let runner = ConversationRunner(probe: { environment, index in
            .success(conversationProbe(environment, extraCapabilities: [
                index == 1 ? CtlCapability.taskContinue : CtlCapability.taskSuccessors
            ]))
        }, command: { _, _ in Issue.record("must not dispatch"); return convRaw(exit: 0) })
        let client = conversationClient(runner)
        // when
        let first = await client.continueTask("prefix")
        let second = await client.continueTask("prefix")
        // then
        #expect(first == .notDispatched(.missingCapability(CtlCapability.taskSuccessors)))
        #expect(second == .notDispatched(.missingCapability(CtlCapability.taskContinue)))
        #expect(runner.probeCount == 2)
        #expect(runner.commandCalls.isEmpty)
    }

    @Test func givenCanonicalRefusalAndUnknown_whenContinued_thenEvidenceRetained() async {
        // given
        let refused = runner(LaunchFixture.output("continue-refused"))
        let unknown = runner(LaunchFixture.output("continue-unknown"))
        // when
        let refusal = await conversationClient(refused).continueTask("prefix")
        let uncertainty = await conversationClient(unknown).continueTask("prefix")
        // then
        #expect(refusal == .engineError(ConversationDeliveryEngineError(code: "invalid_params", message: "fixture refusal", data: nil)))
        #expect(uncertainty == .uncertain(.processFailure(.unknownOutcome(message: "fixture: owner did not report; a task may exist"))))
    }

    @Test func givenStoppedChainFixture_whenContinued_thenStructuredRefusalRetained() async throws {
        // given
        let answer = ConvResult.success(ProcessOutput(exitCode: 1, stdout: try ConvFixture.data("ctl-continue-chain-stopped.json"), stderr: ""))
        // when
        let outcome = await conversationClient(runner(answer)).continueTask("prefix")
        // then
        guard case .engineError(let error) = outcome else { Issue.record("expected refusal"); return }
        #expect(error.code == "start_failed")
        #expect(error.data == ["chain_root_task_id": .string("task-continuation-stop"), "reason": .string("chain_stopped")])
    }

    @Test(arguments: ["A_z-09", String(repeating: "a", count: 300)])
    func givenTaskIDGrammar_whenAcknowledged_thenAcceptedWithoutConversationLengthLimit(id: String) async {
        // given
        let runner = runner(convResult(["task_id": .string(id)]))
        // when
        let outcome = await conversationClient(runner).continueTask("prefix")
        // then
        #expect(outcome == .launched(taskID: id))
    }

    @Test(arguments: ["", "a.b", "a b", "é", "a\n", "a/b"])
    func givenMalformedTaskID_whenAcknowledged_thenUncertain(id: String) async {
        // given
        let runner = runner(convResult(["task_id": .string(id)]))
        // when
        let outcome = await conversationClient(runner).continueTask("prefix")
        // then
        #expect(outcome == .uncertain(.inconsistentEnvelope(exitCode: 0, detail: "launch result carries no usable task id")))
    }

    @Test(arguments: [Int32(0), 1, 2, 3])
    func givenPayloadCollisions_whenContinued_thenNeverAcceptedOrRemapped(exit: Int32) async {
        // given
        let payloads: [String: JSONValue] = ["result": .object(["task_id": .string("ok")]),
                                            "error": .object(["code": .string("usage")]),
                                            "unknown": .object(["message": .string("maybe")])]
        for keys in [["result", "error"], ["result", "unknown"], ["error", "unknown"], ["result", "error", "unknown"]] {
            let body = payloads.filter { keys.contains($0.key) }
            let runner = runner(convDocument(body, exit: exit))
            // when
            let outcome = await conversationClient(runner).continueTask("prefix")
            // then
            guard case .uncertain(.inconsistentEnvelope) = outcome else { Issue.record("collision reinterpreted: \(outcome)"); continue }
            #expect(runner.commandCalls.count == 1)
        }
    }

    @Test func givenFailuresAndContradictions_whenContinued_thenNoReplay() async {
        // given
        let answers: [ConvResult] = [convRaw(exit: 0, stdout: "broken"), convRaw(exit: 0, timedOut: true),
                                    convResult(["task_id": .number(3)]), convResult([:], exit: 1),
                                    convError(code: "future", exit: 0), convError(code: "future", exit: 2),
                                    convError(code: "future", exit: 3), convDocument(["unknown": .string("bad")], exit: 3),
                                    .failure(.timedOut(tool: "ctl", seconds: 75))]
        for answer in answers {
            let runner = runner(answer)
            // when
            let outcome = await conversationClient(runner).continueTask("prefix")
            // then
            guard case .uncertain = outcome else { Issue.record("expected uncertain: \(outcome)"); continue }
            #expect(runner.commandCalls.count == 1)
        }
    }

    @Test func givenProvenLaunchFailure_whenContinued_thenNotDispatched() async {
        // given
        let runner = runner(.failure(.launchFailed(tool: "ctl", detail: "spawn failed")))
        // when
        let outcome = await conversationClient(runner).continueTask("prefix")
        // then
        #expect(outcome == .notDispatched(.launchFailed(tool: "ctl", detail: "spawn failed")))
    }

    @Test func givenCancellationBeforeProbe_whenContinued_thenNothingRuns() async {
        // given
        let runner = runner(LaunchFixture.output("continue-accepted"))
        let client = conversationClient(runner)
        // when
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.continueTask("prefix")
        }.value
        // then
        #expect(outcome == .notDispatched(.cancelledBeforeLaunch))
        #expect(runner.allCalls.isEmpty)
    }

    @Test(arguments: [false, true])
    func givenSupersessionBeforeOrDuringProbe_whenContinued_thenNoLaunch(during: Bool) async {
        // given
        let current = Collector<Bool>()
        let runner = ConversationRunner(probe: { environment, _ in
            current.add(false)
            return .success(conversationProbe(environment, extraCapabilities: [CtlCapability.taskContinue, CtlCapability.taskSuccessors]))
        }, command: { _, _ in Issue.record("must not dispatch"); return convRaw(exit: 0) })
        var client = conversationClient(runner)
        client.operationIsCurrent = { during && current.values.isEmpty }
        // when
        let outcome = await client.continueTask("prefix")
        // then
        #expect(outcome == .notDispatched(.cancelledBeforeLaunch))
        #expect(runner.probeCount == (during ? 1 : 0))
        #expect(runner.commandCalls.isEmpty)
    }

    @Test func givenCancellationDuringProbe_whenContinued_thenNoLaunch() async {
        // given
        let runner = ConversationRunner(probe: { environment, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .success(conversationProbe(environment, extraCapabilities: [CtlCapability.taskContinue, CtlCapability.taskSuccessors]))
        }, command: { _, _ in Issue.record("must not dispatch"); return convRaw(exit: 0) })
        let client = conversationClient(runner)
        // when
        let outcome = await Task { await client.continueTask("prefix") }.value
        // then
        #expect(outcome == .notDispatched(.cancelledBeforeLaunch))
        #expect(runner.commandCalls.isEmpty)
    }

    @Test func givenCancellationAndSupersessionAfterDispatch_whenAcknowledged_thenReceiptRetained() async {
        // given
        let superseded = Collector<Bool>()
        let runner = ConversationRunner(probe: { environment, _ in
            .success(conversationProbe(environment, extraCapabilities: [CtlCapability.taskContinue, CtlCapability.taskSuccessors]))
        }, command: { _, _ in
            superseded.add(true)
            withUnsafeCurrentTask { $0?.cancel() }
            return LaunchFixture.output("continue-accepted")
        })
        var client = conversationClient(runner)
        client.operationIsCurrent = { superseded.values.isEmpty }
        let operation = client
        // when
        let outcome = await Task { await operation.continueTask("prefix") }.value
        // then
        #expect(outcome == .launched(taskID: "task-fixture"))
        #expect(runner.commandCalls.count == 1)
    }
}
