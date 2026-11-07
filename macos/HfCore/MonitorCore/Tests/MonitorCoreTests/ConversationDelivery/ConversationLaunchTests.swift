import Foundation
@testable import MonitorCore
import Testing

// MARK: - Launch fixture access

/// Reads the vendored `ctl-launch-*` fixtures with the exit code the manifest records. These are
/// synthetic engine outputs recorded by the contract owner, not live engine evidence.
enum LaunchFixture {
    static func file(_ stem: String) -> String { "ctl-launch-" + stem + ".json" }

    static func exitCode(_ stem: String) throws -> Int32 {
        let manifest = try #require(JSONValue.parse(ConvFixture.data("manifest.json"))?.objectValue)
        let entry = try #require(manifest["cases"]?.objectValue?[file(stem)]?.objectValue)
        return Int32(try #require(entry["exit_code"]?.intValue))
    }

    static func output(_ stem: String) -> ConvResult {
        do {
            return .success(ProcessOutput(exitCode: try exitCode(stem), stdout: try ConvFixture.data(file(stem)), stderr: ""))
        } catch {
            return .failure(.unreadable(tool: "fixture", exitCode: 0, stderr: "\(error)"))
        }
    }
}

// MARK: - ConversationLaunchTests

/// Profiled launch: argv rendering, phase classification and timeouts. Tests named after a
/// `ctl-launch-*` fixture read that vendored file; tests whose given says "fixture answer" use one
/// as a canned success. Every other runner answer is synthetic and labelled so.
struct ConversationLaunchTests {
    private var fullRequest: RunRequest {
        RunRequest(backend: "claude", repo: "/repo", prompt: "-leading dash prompt", freedom: "write_in_repo",
                   reasoningEffort: "high", group: "grp", title: "A title", model: "model-x", maxTurns: 7,
                   callerApprovals: true)
    }

    private let fullArguments = [
        "--backend=claude", "--repo=/repo", "--prompt=-leading dash prompt", "--freedom=write_in_repo",
        "--reasoning-effort=high", "--group=grp", "--title=A title", "--model=model-x", "--max-turns=7",
        "--caller-approvals", "--monitor"
    ]

    private let minimal = RunRequest(backend: "claude", repo: "/repo", prompt: "go")

    private func launch(_ request: RunRequest, profile: ConversationLaunchProfile = .native, probe: ConversationRunner.Probe? = nil,
                        command: @escaping @Sendable () -> ConvResult) async -> (outcome: ConversationLaunchOutcome, runner: ConversationRunner) {
        let runner = if let probe {
            ConversationRunner(probe: probe) { _, _ in command() }
        } else {
            ConversationRunner { _, _ in command() }
        }
        return (await conversationClient(runner).conversationLaunch(request, profile: profile), runner)
    }

    private func resume(probe: ConversationRunner.Probe? = nil, maxTurns: Int? = nil,
                        command: @escaping @Sendable () -> ConvResult) async -> (outcome: ConversationLaunchOutcome, runner: ConversationRunner) {
        let runner = if let probe {
            ConversationRunner(probe: probe) { _, _ in command() }
        } else {
            ConversationRunner { _, _ in command() }
        }
        // when
        let outcome = await conversationClient(runner).conversationResume(
            taskID: "task-1", text: "continue", profile: .native, maxTurns: maxTurns)
        return (outcome, runner)
    }

    // MARK: Profile rendering

    @Test func givenProfiles_whenRendered_thenWireValuesAreExact() {
        // then
        #expect(ConversationLaunchProfile.native.wireValue == "native")
        #expect(ConversationLaunchProfile.shippedMedium35High.wireValue == "shipped-medium35-high")
    }

    @Test func givenRunRequest_whenArgumentsRendered_thenArrayIsExactlyTheExistingShape() {
        // given: SYNTHETIC argv
        let minimalArguments = minimal.arguments
        let full = fullRequest.arguments
        // then
        #expect(minimalArguments == ["--backend=claude", "--repo=/repo", "--prompt=go"])
        #expect(full == fullArguments)
        #expect(!full.contains { $0.hasPrefix("--conversation-profile") })
    }

    // MARK: Argv on the wire

    @Test(arguments: [(ConversationLaunchProfile.native, "native"),
                      (ConversationLaunchProfile.shippedMedium35High, "shipped-medium35-high")])
    func givenSyntheticProfiledLaunch_whenLaunched_thenEveryFieldReachesTheCommandWithTheProfileLastAfterOneProbe(
        profile: ConversationLaunchProfile, wire: String
    ) async {
        // given: the ctl-launch-run-accepted fixture answer
        // when
        let run = await launch(fullRequest, profile: profile) { LaunchFixture.output("run-accepted") }
        // then
        #expect(run.runner.allCalls.first == ["version-info", "--json"])
        #expect(run.runner.commandCalls == [["run"] + fullArguments + ["--conversation-profile=\(wire)", "--json"]])
        #expect(run.runner.probeCount == 1)
    }

    @Test(arguments: [ConversationLaunchProfile.native, .shippedMedium35High])
    func givenSyntheticProfiledResume_whenLaunched_thenAllFieldsReachTheCommandWithSeparatedPositionals(profile: ConversationLaunchProfile) async {
        // given: the ctl-launch-resume-accepted fixture answer
        let runner = ConversationRunner { _, _ in LaunchFixture.output("resume-accepted") }
        // when
        let outcome = await conversationClient(runner).conversationResume(
            taskID: "task-1", text: "--looks like an option", profile: profile, maxTurns: 3)
        // then
        #expect(outcome == .launched(taskID: "task-fixture"))
        #expect(runner.commandCalls == [["resume", "--max-turns=3", "--conversation-profile=\(profile.wireValue)", "--json", "--",
                                         "task-1", "--looks like an option"]])
    }

    @Test func givenResumeWithoutMaxTurns_whenLaunched_thenNoTurnCapOptionIsRendered() async {
        // given: the ctl-launch-resume-accepted fixture answer
        // when
        let run = await resume { LaunchFixture.output("resume-accepted") }
        // then
        #expect(run.runner.commandCalls == [["resume", "--conversation-profile=native", "--json", "--", "task-1", "continue"]])
    }

    // MARK: Fixtures

    @Test func givenRunAcceptedFixture_whenLaunched_thenLaunchedWithTheTaskID() async throws {
        // given
        #expect(try LaunchFixture.exitCode("run-accepted") == 0)
        // when
        let run = await launch(minimal) { LaunchFixture.output("run-accepted") }
        // then
        #expect(run.outcome == .launched(taskID: "task-fixture"))
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test func givenResumeAcceptedFixture_whenResumed_thenLaunchedWithTheTaskID() async throws {
        // given
        #expect(try LaunchFixture.exitCode("resume-accepted") == 0)
        // when
        let run = await resume { LaunchFixture.output("resume-accepted") }
        // then
        #expect(run.outcome == .launched(taskID: "task-fixture"))
    }

    @Test func givenRunRefusedFixture_whenLaunched_thenEngineErrorAndNeverNotDispatched() async throws {
        // given
        #expect(try LaunchFixture.exitCode("run-refused") == 1)
        // when
        let run = await launch(minimal) { LaunchFixture.output("run-refused") }
        // then
        #expect(run.outcome == .engineError(ConversationDeliveryEngineError(code: "invalid_params", message: "fixture refusal", data: nil)))
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test func givenResumeRefusedFixture_whenResumed_thenEngineError() async throws {
        // given
        #expect(try LaunchFixture.exitCode("resume-refused") == 1)
        // when
        let run = await resume { LaunchFixture.output("resume-refused") }
        // then
        #expect(run.outcome == .engineError(ConversationDeliveryEngineError(code: "invalid_params", message: "fixture refusal", data: nil)))
    }

    @Test func givenRunUnknownFixture_whenLaunched_thenUncertainAtExitThree() async throws {
        // given
        #expect(try LaunchFixture.exitCode("run-unknown") == 3)
        // when
        let run = await launch(minimal) { LaunchFixture.output("run-unknown") }
        // then
        #expect(run.outcome == .uncertain(.processFailure(.unknownOutcome(message: "fixture: owner did not report; a task may exist"))))
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test func givenResumeUnknownFixture_whenResumed_thenUncertainAtExitThree() async throws {
        // given
        #expect(try LaunchFixture.exitCode("resume-unknown") == 3)
        // when
        let run = await resume { LaunchFixture.output("resume-unknown") }
        // then
        #expect(run.outcome == .uncertain(.processFailure(.unknownOutcome(message: "fixture: owner did not report; a task may exist"))))
    }

    @Test func givenUnknownOperationFixtureAtExitTwo_whenLaunched_thenNotDispatchedAsUsageRejected() async throws {
        // given: the validated usage envelope at exit 2
        #expect(try LaunchFixture.exitCode("unknown-operation") == 2)
        // when
        let run = await launch(minimal) { LaunchFixture.output("unknown-operation") }
        // then
        guard case .notDispatched(.usageRejected(let detail)) = run.outcome else {
            Issue.record("expected usageRejected, got \(run.outcome)")
            return
        }
        #expect(detail.contains("invalid choice"))
    }

    // MARK: Engine errors without a fixture

    @Test(arguments: ["unsupported", "invalid_params"])
    func givenSyntheticExitOneEnvelope_whenLaunched_thenEngineErrorKeepingCodeAndData(code: String) async {
        // given: SYNTHETIC; `unsupported` has no fixture
        let data: JSONValue = .object(["published": .bool(false)])
        // when
        let run = await launch(minimal) { convError(code: code, message: "refused", data: data, exit: 1) }
        // then
        #expect(run.outcome == .engineError(ConversationDeliveryEngineError(
            code: code, message: "refused", data: ["published": .bool(false)])))
    }

    @Test func givenSyntheticExitOneUnsupported_whenResumed_thenEngineErrorNotNotDispatched() async {
        // given: SYNTHETIC
        // when
        let run = await resume { convError(code: "unsupported", message: "no row", exit: 1) }
        // then
        #expect(run.outcome == .engineError(ConversationDeliveryEngineError(code: "unsupported", message: "no row", data: nil)))
    }

    @Test func givenSyntheticUsageEnvelopeAtExitOne_whenLaunched_thenEngineErrorBecauseOnlyExitTwoProvesNonDispatch() async {
        // given: SYNTHETIC
        // when
        let run = await launch(minimal) { convError(code: "usage", message: "bad", exit: 1) }
        // then
        #expect(run.outcome == .engineError(ConversationDeliveryEngineError(code: "usage", message: "bad", data: nil)))
    }

    // MARK: Pre-launch failures

    @Test func givenMissingCapability_whenLaunched_thenNotDispatchedAndNoCommandRuns() async {
        // given: SYNTHETIC probe
        // when
        let run = await launch(minimal, probe: { environment, _ in .success(conversationProbe(environment, capability: false)) },
                               command: { Issue.record("must not launch"); return convRaw(exit: 0) })
        // then
        #expect(run.outcome == .notDispatched(.missingCapability(CtlCapability.conversationDelivery)))
        #expect(run.runner.commandCalls.isEmpty)
        #expect(run.runner.allCalls == [["version-info", "--json"]])
    }

    @Test func givenMissingCapability_whenResumed_thenNotDispatchedAndNoCommandRuns() async {
        // given: SYNTHETIC probe
        // when
        let run = await resume(probe: { environment, _ in .success(conversationProbe(environment, capability: false)) },
                               command: { Issue.record("must not launch"); return convRaw(exit: 0) })
        // then
        #expect(run.outcome == .notDispatched(.missingCapability(CtlCapability.conversationDelivery)))
        #expect(run.runner.commandCalls.isEmpty)
    }

    @Test func givenProbeFailure_whenLaunched_thenNotDispatchedAsProbeFailed() async {
        // given: SYNTHETIC
        let failure = ToolError.launchFailed(tool: "harflow-ctl", detail: "no such file")
        // when
        let run = await launch(minimal, probe: { _, _ in .failure(failure) }, command: { convRaw(exit: 0) })
        // then
        #expect(run.outcome == .notDispatched(.probeFailed(failure)))
        #expect(run.runner.commandCalls.isEmpty)
    }

    @Test func givenProbeFailure_whenResumed_thenNotDispatchedAsProbeFailed() async {
        // given: SYNTHETIC
        let failure = ToolError.timedOut(tool: "harflow-ctl version-info", seconds: 10)
        // when
        let run = await resume(probe: { _, _ in .failure(failure) }, command: { convRaw(exit: 0) })
        // then
        #expect(run.outcome == .notDispatched(.probeFailed(failure)))
        #expect(run.runner.commandCalls.isEmpty)
    }

    @Test func givenCallerCancelledBeforeAnything_whenLaunched_thenNotDispatchedAndNothingRuns() async {
        // given
        let runner = ConversationRunner { _, _ in Issue.record("must not launch"); return convRaw(exit: 0) }
        let client = conversationClient(runner)
        let request = minimal
        // when
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.conversationLaunch(request, profile: .native)
        }.value
        // then
        #expect(outcome == .notDispatched(.cancelledBeforeLaunch))
        #expect(runner.allCalls.isEmpty)
    }

    @Test func givenCallerCancelledBeforeAnything_whenResumed_thenNotDispatchedAndNothingRuns() async {
        // given
        let runner = ConversationRunner { _, _ in Issue.record("must not launch"); return convRaw(exit: 0) }
        let client = conversationClient(runner)
        // when
        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.conversationResume(taskID: "task-1", text: "go", profile: .native)
        }.value
        // then
        #expect(outcome == .notDispatched(.cancelledBeforeLaunch))
        #expect(runner.allCalls.isEmpty)
    }

    @Test func givenOwnerGenerationChangedBeforeProbe_whenLaunched_thenNotDispatchedWithoutProbing() async {
        // given
        let runner = ConversationRunner { _, _ in Issue.record("must not launch"); return convRaw(exit: 0) }
        var client = conversationClient(runner)
        client.operationIsCurrent = { false }
        // when
        let outcome = await client.conversationLaunch(minimal, profile: .native)
        // then
        #expect(outcome == .notDispatched(.cancelledBeforeLaunch))
        #expect(runner.allCalls.isEmpty)
    }

    @Test func givenLaunchFailure_whenLaunched_thenNotDispatchedAsLaunchFailed() async {
        // given: SYNTHETIC
        // when
        let run = await launch(minimal) { .failure(.launchFailed(tool: "harflow-ctl", detail: "posix_spawn failed")) }
        // then
        #expect(run.outcome == .notDispatched(.launchFailed(tool: "harflow-ctl", detail: "posix_spawn failed")))
    }

    // MARK: Exit two

    @Test func givenSyntheticExitTwoUsageEnvelope_whenLaunched_thenNotDispatchedAsUsageRejected() async {
        // given: SYNTHETIC
        // when
        let run = await launch(minimal) { convError(code: "usage", message: "bad profile", exit: 2) }
        // then
        #expect(run.outcome == .notDispatched(.usageRejected(detail: "bad profile")))
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test func givenSyntheticExitTwoUsageEnvelope_whenResumed_thenNotDispatchedAsUsageRejected() async {
        // given: SYNTHETIC
        // when
        let run = await resume { convError(code: "usage", message: "bad profile", exit: 2) }
        // then
        #expect(run.outcome == .notDispatched(.usageRejected(detail: "bad profile")))
    }

    @Test(arguments: ["usage: harflow-ctl run [-h]\nKeyboardInterrupt", "harflow-ctl: error: unrecognized arguments: --x", ""])
    func givenSyntheticExitTwoWithoutEnvelope_whenLaunched_thenUncertain(stderr: String) async {
        // given: SYNTHETIC; a SIGINT-style exit 2 is not proof of non-dispatch
        // when
        let run = await launch(minimal) { convRaw(exit: 2, stderr: stderr) }
        // then
        #expect(run.outcome == .uncertain(.unreadableOutput(exitCode: 2, stderr: stderr)))
    }

    @Test func givenSyntheticExitTwoWithoutEnvelope_whenResumed_thenUncertain() async {
        // given: SYNTHETIC
        // when
        let run = await resume { convRaw(exit: 2, stderr: "KeyboardInterrupt") }
        // then
        #expect(run.outcome == .uncertain(.unreadableOutput(exitCode: 2, stderr: "KeyboardInterrupt")))
    }

    @Test func givenSyntheticExitTwoWithNonUsageCode_whenLaunched_thenEngineErrorIsNotAllowedAndItIsUncertain() async {
        // given: SYNTHETIC; a non-usage code at exit 2 is inconsistent, never a refusal or non-dispatch
        // when
        let run = await launch(minimal) { convError(code: "unsupported", message: "x", exit: 2) }
        // then
        #expect(run.outcome == .uncertain(.inconsistentEnvelope(exitCode: 2, detail: "error with exit other than 1")))
    }

    @Test func givenSyntheticExitTwoInvalidChoiceWithoutEnvelope_whenLaunched_thenUncertainBecauseStderrIsNeverProof() async {
        // given: SYNTHETIC; the transport reads this as an unsupported command, which the
        // launch classifier maps to unreadable output
        let stderr = "harflow-ctl: error: argument command: invalid choice: 'run'"
        // when
        let run = await launch(minimal) { convRaw(exit: 2, stderr: stderr) }
        // then
        #expect(run.outcome == .uncertain(.unreadableOutput(exitCode: 2, stderr: stderr)))
    }

    @Test func givenSyntheticOversizedStdout_whenLaunched_thenUncertainOutputTooLarge() async {
        // given: SYNTHETIC
        let size = CtlClient.conversationMutationStdoutCap + 1
        // when
        let run = await launch(minimal) { convRaw(exit: 0, stdout: String(repeating: "x", count: size)) }
        // then
        #expect(run.outcome == .uncertain(.outputTooLarge(bytes: size)))
    }

    @Test(arguments: [(Int32(0), "neither result nor error"), (Int32(1), "neither result nor error")])
    func givenSyntheticUnknownDocumentAtExitZeroOrOne_whenLaunched_thenUncertainInconsistent(exit: Int32, detail: String) async throws {
        // given: SYNTHETIC; only exit 3 carries the owner-never-answered meaning
        let stdout = try #require(String(bytes: ConvFixture.data("ctl-launch-run-unknown.json"), encoding: .utf8))
        // when
        let run = await launch(minimal) { convRaw(exit: exit, stdout: stdout) }
        // then
        #expect(run.outcome == .uncertain(.inconsistentEnvelope(exitCode: exit, detail: detail)))
    }

    // MARK: Uncertain

    @Test func givenSyntheticUnparseableOutput_whenLaunched_thenUncertain() async {
        // given: SYNTHETIC
        // when
        let run = await launch(minimal) { convRaw(exit: 0, stdout: "not json", stderr: "oops") }
        // then
        #expect(run.outcome == .uncertain(.unreadableOutput(exitCode: 0, stderr: "oops")))
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test func givenSyntheticUnparseableOutputAtExitThree_whenLaunched_thenUncertain() async {
        // given: SYNTHETIC
        // when
        let run = await launch(minimal) { convRaw(exit: 3, stdout: "garbage") }
        guard case .uncertain = run.outcome else { Issue.record("expected uncertain, got \(run.outcome)"); return }
    }

    @Test func givenSyntheticUnparseableOutput_whenResumed_thenUncertain() async {
        // given: SYNTHETIC
        // when
        let run = await resume { convRaw(exit: 0, stdout: "not json") }
        guard case .uncertain = run.outcome else { Issue.record("expected uncertain, got \(run.outcome)"); return }
    }

    @Test func givenSyntheticCommandTimeout_whenLaunched_thenUncertainWithTheRunTimeout() async {
        // given: SYNTHETIC
        // when
        let run = await launch(minimal) { convRaw(exit: 0, timedOut: true) }
        // then
        #expect(run.outcome == .uncertain(.timedOut(seconds: CtlClient.startTimeout)))
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test func givenSyntheticRunnerFailureAfterLaunch_whenLaunched_thenUncertain() async {
        // given: SYNTHETIC
        let failure = ToolError.timedOut(tool: "harflow-ctl", seconds: 75)
        // when
        let run = await launch(minimal) { .failure(failure) }
        // then
        #expect(run.outcome == .uncertain(.processFailure(failure)))
    }

    @Test(arguments: [
        ["task_id": JSONValue.string("")],
        ["task_id": JSONValue.number(5)],
        ["task_id": JSONValue.string("bad\nid")],
        [:]
    ] as [[String: JSONValue]])
    func givenSyntheticSuccessWithoutUsableTaskID_whenLaunched_thenUncertainInconsistent(result: [String: JSONValue]) async {
        // given: SYNTHETIC
        // when
        let run = await launch(minimal) { convResult(result) }
        // then
        #expect(run.outcome == .uncertain(.inconsistentEnvelope(exitCode: 0, detail: "launch result carries no usable task id")))
        #expect(run.runner.commandCalls.count == 1)
    }

    @Test func givenSyntheticSuccessWithoutUsableTaskID_whenResumed_thenUncertainInconsistent() async {
        // given: SYNTHETIC
        // when
        let run = await resume { convResult([:]) }
        // then
        #expect(run.outcome == .uncertain(.inconsistentEnvelope(exitCode: 0, detail: "launch result carries no usable task id")))
    }

    @Test func givenSyntheticResultEnvelopeAtExitOne_whenLaunched_thenUncertainInconsistentAndNeverLaunched() async {
        // given: SYNTHETIC
        // when
        let run = await launch(minimal) { convResult(["task_id": .string("task-1")], exit: 1) }
        // then
        #expect(run.outcome == .uncertain(.inconsistentEnvelope(exitCode: 1, detail: "result with non-zero exit")))
    }

    // MARK: No retries

    @Test func givenSyntheticNonAcceptedAnswers_whenLaunchedOrResumed_thenExactlyOneCommandRunsEach() async {
        // given: SYNTHETIC
        let answers = [convRaw(exit: 3, stdout: "x"), convError(code: "unsupported"), convRaw(exit: 0, timedOut: true),
                       convError(code: "usage", exit: 2), .failure(.launchFailed(tool: "harflow-ctl", detail: "x"))]
        for answer in answers {
            // when
            let launched = await launch(minimal) { answer }
            let resumed = await resume { answer }
            // then
            #expect(launched.runner.commandCalls.count == 1)
            #expect(resumed.runner.commandCalls.count == 1)
        }
    }

    // MARK: Timeouts

    @Test func givenLaunchAndResume_whenLaunched_thenBothUseTheExistingRunTimeout() async {
        // given: the ctl-launch-run-accepted fixture answer
        let runner = ConversationRunner { _, _ in LaunchFixture.output("run-accepted") }
        let client = conversationClient(runner)
        // when
        _ = await client.conversationLaunch(minimal, profile: .native)
        _ = await client.conversationResume(taskID: "task-1", text: "go", profile: .native)
        // then
        #expect(CtlClient.startTimeout == 75)
        #expect(runner.commandTimeouts == [CtlClient.startTimeout, CtlClient.startTimeout])
    }

    @Test func givenSendAndControl_whenLaunched_thenTheirMutationTimeoutIsUnchanged() async throws {
        // given
        let runner = ConversationRunner { _, _ in ConvFixture.output("send-ack") }
        let client = conversationClient(runner)
        // when
        _ = try await client.conversationSend(convSend())
        _ = try await client.conversationControl(convControl())
        // then
        #expect(CtlClient.conversationMutationTimeout == 120)
        #expect(runner.commandTimeouts == [120, 120])
    }

    @Test func givenSendTimingOut_whenLaunched_thenUncertainReportsTheMutationTimeoutAndLaunchReportsItsOwn() async throws {
        // given: SYNTHETIC
        let sendRunner = ConversationRunner { _, _ in convRaw(exit: 0, timedOut: true) }
        let request = try convSend()
        // when
        let sendOutcome = await conversationClient(sendRunner).conversationSend(request)
        let launchRun = await launch(minimal) { convRaw(exit: 0, timedOut: true) }
        // then
        #expect(sendOutcome == .uncertain(request, cause: .timedOut(seconds: 120)))
        #expect(launchRun.outcome == .uncertain(.timedOut(seconds: 75)))
    }
}
