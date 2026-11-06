import Foundation
@testable import MonitorCore
import Testing

// MARK: - ConversationDeliveryTransportTests

/// Argv, probe, capability gate, request file and prepare transport. Receipts here are the
/// `send-ack`/`cancel-ack` fixtures; every other runner answer is synthetic.
struct ConversationDeliveryTransportTests {
    /// A path whose parent does not exist, so the private directory cannot be created.
    private func missingInputDirectory() -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("harflow-missing-\(UUID().uuidString)", isDirectory: true)
        return parent.appendingPathComponent("nested", isDirectory: true)
    }

    @Test func givenSend_whenLaunched_thenArgvOrdersMonitorJsonThenSeparatedRequestFileAfterAProbe() async throws {
        // given
        let request = try convSend()
        let runner = ConversationRunner { _, _ in ConvFixture.output("send-ack") }
        // when
        _ = await conversationClient(runner).conversationSend(request)
        // then
        let command = try #require(runner.commandCalls.first)
        #expect(runner.allCalls.first == ["version-info", "--json"])
        #expect(Array(command.dropLast()) == ["conversation-send", "--monitor", "--json", "--"])
        #expect(command.last?.hasSuffix("/request.json") == true)
        #expect(runner.commandCalls.count == 1)
    }

    @Test func givenControl_whenLaunched_thenArgvUsesTheControlCommand() async throws {
        // given
        let request = try convControl()
        let runner = ConversationRunner { _, _ in ConvFixture.output("cancel-ack") }
        // when
        _ = await conversationClient(runner).conversationControl(request)
        // then
        let command = try #require(runner.commandCalls.first)
        #expect(Array(command.dropLast()) == ["conversation-control", "--monitor", "--json", "--"])
    }

    @Test func givenSendAndControl_whenLaunched_thenCommandTimeoutIsOneHundredTwentySeconds() async throws {
        // given
        let runner = ConversationRunner { _, _ in ConvFixture.output("send-ack") }
        let client = conversationClient(runner)
        // when
        _ = try await client.conversationSend(convSend())
        _ = try await client.conversationControl(convControl())
        // then
        #expect(runner.commandTimeouts == [120, 120])
    }

    @Test func givenTwoOperations_whenLaunched_thenEachOneProbesFreshWithNoCaching() async throws {
        // given
        let runner = ConversationRunner { _, _ in ConvFixture.output("send-ack") }
        let client = conversationClient(runner)
        // when
        _ = try await client.conversationSend(convSend())
        _ = try await client.conversationSend(convSend())
        // then
        #expect(runner.allCalls.map(\.first) == ["version-info", "conversation-send", "version-info", "conversation-send"])
        #expect(runner.probeCount == 2)
    }

    @Test func givenCapabilityDisappearsBetweenCalls_whenSecondSendRuns_thenOnlyTheFirstDispatches() async throws {
        // given
        let runner = ConversationRunner(
            probe: { environment, index in .success(conversationProbe(environment, capability: index == 1)) },
            command: { _, _ in ConvFixture.output("send-ack") }
        )
        let client = conversationClient(runner)
        let first = try convSend()
        let second = try convSend(id: ConvID.second)
        // when
        let firstOutcome = await client.conversationSend(first)
        let secondOutcome = await client.conversationSend(second)
        // then
        #expect(firstOutcome.isAccepted)
        #expect(secondOutcome == .notDispatched(second, cause: .missingCapability(CtlCapability.conversationDelivery)))
        #expect(runner.commandCalls.count == 1)
    }

    @Test func givenMissingCapability_whenSendingOrControlling_thenNothingIsLaunchedAndRequestIsKept() async throws {
        // given
        let runner = ConversationRunner(
            probe: { environment, _ in .success(conversationProbe(environment, capability: false, extraCapabilities: ["messaging.v1"])) },
            command: { _, _ in Issue.record("command must not launch"); return convRaw(exit: 0) }
        )
        let client = conversationClient(runner)
        let send = try convSend()
        let control = try convControl()
        // when
        let sendOutcome = await client.conversationSend(send)
        let controlOutcome = await client.conversationControl(control)
        // then
        #expect(sendOutcome == .notDispatched(send, cause: .missingCapability("conversation-delivery.v1")))
        #expect(controlOutcome == .notDispatched(control, cause: .missingCapability("conversation-delivery.v1")))
        #expect(runner.commandCalls.isEmpty)
        #expect(runner.allCalls == [["version-info", "--json"], ["version-info", "--json"]])
    }

    @Test func givenRequestFile_whenCommandRuns_thenFileIsPrivateInAPrivateDirectoryAndRemovedAfterwards() async throws {
        // given
        let request = try convSend()
        let seen = Collector<RequestFileSnapshot>()
        let runner = ConversationRunner { arguments, _ in
            seen.add(snapshotRequestFile(arguments))
            return ConvFixture.output("send-ack")
        }
        // when
        let outcome = await conversationClient(runner).conversationSend(request)
        // then
        let snapshot = try #require(seen.values.first)
        #expect(outcome.isAccepted)
        #expect(snapshot.fileMode == 0o600)
        #expect(snapshot.directoryMode == 0o700)
        #expect(snapshot.body == request.body)
        #expect(snapshot.directoryName.hasPrefix("harflow-conversation-"))
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: snapshot.path).deletingLastPathComponent().path))
    }

    @Test func givenControlRequestFile_whenCommandRuns_thenFileHoldsTheControlBodyPrivately() async throws {
        // given
        let request = try convControl(operation: .promoteNow)
        let seen = Collector<RequestFileSnapshot>()
        let runner = ConversationRunner { arguments, _ in
            seen.add(snapshotRequestFile(arguments))
            return ConvFixture.output("promote-ack")
        }
        // when
        _ = await conversationClient(runner).conversationControl(request)
        // then
        let snapshot = try #require(seen.values.first)
        #expect(snapshot.fileMode == 0o600)
        #expect(snapshot.directoryMode == 0o700)
        #expect(snapshot.body == request.body)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
    }

    @Test func givenInputDirectoryThatDoesNotExist_whenSending_thenNotDispatchedAsInputFileAndNothingLaunches() async throws {
        // given: SYNTHETIC; the internal base-directory seam points at a path that cannot be created
        let missing = missingInputDirectory()
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        let request = try convSend()
        let runner = ConversationRunner { _, _ in Issue.record("command must not launch"); return convRaw(exit: 0) }
        // when
        let outcome = await conversationClient(runner).conversationMutate(
            command: "conversation-send", body: request.body, request: request, inputDirectory: missing
        ) { ConversationDeliverySendReceipt(raw: $0, matching: request) }
        // then
        guard case .notDispatched(let kept, .inputFile) = outcome else { Issue.record("expected inputFile, got \(outcome)"); return }
        #expect(kept == request)
        #expect(runner.commandCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func givenInputDirectoryThatDoesNotExist_whenControlling_thenNotDispatchedAsInputFileAndNothingLaunches() async throws {
        // given: SYNTHETIC
        let missing = missingInputDirectory()
        let request = try convControl()
        let runner = ConversationRunner { _, _ in Issue.record("command must not launch"); return convRaw(exit: 0) }
        // when
        let outcome = await conversationClient(runner).conversationMutate(
            command: "conversation-control", body: request.body, request: request, inputDirectory: missing
        ) { ConversationDeliveryControlReceipt(raw: $0, matching: request) }
        // then
        guard case .notDispatched(let kept, .inputFile) = outcome else { Issue.record("expected inputFile, got \(outcome)"); return }
        #expect(kept == request)
        #expect(runner.commandCalls.isEmpty)
    }

    @Test(arguments: ["timeout", "failure", "garbage"])
    func givenCommandThatDoesNotSucceed_whenFinished_thenRequestFileIsStillRemoved(mode: String) async throws {
        // given
        let seen = Collector<String>()
        let runner = ConversationRunner { arguments, _ in
            seen.add(arguments.last ?? "")
            switch mode {
            case "timeout": return convRaw(exit: 0, timedOut: true)
            case "failure": return .failure(.notFound(tool: "harflow-ctl", searched: []))
            default: return convRaw(exit: 0, stdout: "not json")
            }
        }
        // when
        _ = try await conversationClient(runner).conversationSend(convSend())
        // then
        let path = try #require(seen.values.first)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }

    @Test func givenTwoSends_whenLaunched_thenEachUsesItsOwnPrivateDirectory() async throws {
        // given
        let seen = Collector<RequestFileSnapshot>()
        let runner = ConversationRunner { arguments, _ in
            seen.add(snapshotRequestFile(arguments))
            return ConvFixture.output("send-ack")
        }
        let client = conversationClient(runner)
        // when
        _ = await client.conversationSend(try convSend())
        _ = await client.conversationSend(try convSend())
        // then
        let paths = seen.values.map(\.path)
        #expect(paths.count == 2)
        #expect(Set(paths).count == 2)
    }

    // MARK: Prepare

    @Test func givenPrepare_whenLaunched_thenArgvIsMonitorJsonAndOptionLikeIdIsProtectedByTheSeparator() async throws {
        // given
        let runner = ConversationRunner { _, _ in ConvFixture.output("empty") }
        // when
        _ = await conversationClient(runner).conversationPrepare(taskID: "--help")
        // then
        #expect(runner.commandCalls == [["conversation-prepare", "--monitor", "--json", "--", "--help"]])
        #expect(runner.commandTimeouts == [60])
        #expect(runner.allCalls.first == ["version-info", "--json"])
    }

    @Test func givenMissingCapability_whenPreparing_thenNothingIsLaunchedAndCopyNamesTheCapability() async {
        // given
        let runner = ConversationRunner(
            probe: { environment, _ in .success(conversationProbe(environment, capability: false)) },
            command: { _, _ in Issue.record("command must not launch"); return convRaw(exit: 0) }
        )
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        guard case .failure(let error) = result, case .unsupportedCommand(_, let command, let detail) = error else {
            Issue.record("expected unsupportedCommand, got \(result)")
            return
        }
        #expect(command == "conversation-prepare")
        #expect(detail == "Missing capability conversation-delivery.v1")
        #expect(error.message.contains("does not support capability `conversation-delivery.v1`"))
        #expect(!error.message.contains("predates this app"))
        #expect(runner.commandCalls.isEmpty)
    }

    @Test func givenOtherUsageErrors_whenMessageRead_thenExistingCopyIsUnchanged() {
        // given
        let generic = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "x", detail: "invalid choice")
        let messaging = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "send", detail: "Missing capability messaging.v1")
        // when / then
        #expect(generic.message.contains("predates this app"))
        #expect(messaging.message.contains("`messaging.v1`"))
        #expect(!messaging.message.contains("conversation-delivery.v1"))
    }

    @Test(arguments: ["", "has\nnewline", String(repeating: "x", count: 257)])
    func givenInvalidTaskID_whenPreparing_thenNoProcessLaunches(taskID: String) async {
        // given
        let runner = ConversationRunner { _, _ in Issue.record("must not launch"); return convRaw(exit: 0) }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: taskID)
        // then
        guard case .failure(.unreadable) = result else { Issue.record("expected unreadable, got \(result)"); return }
        #expect(runner.allCalls.isEmpty)
    }

    @Test func givenOversizeButValidProjection_whenPrepared_thenItIsRefusedAsUnreadable() async throws {
        // given: the empty fixture padded past 32 MiB with trailing spaces (SYNTHETIC padding)
        let cap = 32 << 20
        var padded = try ConvFixture.data(ConvFixture.file("empty"))
        padded.append(Data(repeating: 0x20, count: cap + 1 - padded.count))
        let output = ProcessOutput(exitCode: 0, stdout: padded, stderr: "")
        let runner = ConversationRunner { _, _ in .success(output) }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        guard case .failure(.unreadable(_, _, let stderr)) = result else { Issue.record("expected unreadable, got \(result)"); return }
        #expect(stderr.contains("exceeded document byte limit"))
    }

    @Test func givenInvalidJSONOverTheCap_whenPrepared_thenTheCapIsReportedNotAParseFailure() async {
        // given: SYNTHETIC; non-JSON bytes over 32 MiB. A parse-first implementation would report the garbage
        // stderr, only a size-first check reports the cap.
        let cap = 32 << 20
        let output = ProcessOutput(exitCode: 0, stdout: Data(repeating: 0x78, count: cap + 1), stderr: "parse-marker")
        let runner = ConversationRunner { _, _ in .success(output) }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        guard case .failure(.unreadable(_, let exitCode, let stderr)) = result else { Issue.record("expected unreadable, got \(result)"); return }
        #expect(exitCode == 0)
        #expect(stderr.contains("exceeded document byte limit"))
        #expect(!stderr.contains("parse-marker"))
    }

    @Test func givenInvalidJSONExactlyAtTheCap_whenPrepared_thenItIsAParseFailureNotTheCap() async {
        // given: SYNTHETIC; at the cap the size check passes and the garbage reaches the parser
        let cap = 32 << 20
        let output = ProcessOutput(exitCode: 0, stdout: Data(repeating: 0x78, count: cap), stderr: "parse-marker")
        let runner = ConversationRunner { _, _ in .success(output) }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        guard case .failure(.unreadable(_, _, let stderr)) = result else { Issue.record("expected unreadable, got \(result)"); return }
        #expect(!stderr.contains("exceeded document byte limit"))
    }

    @Test func givenPrepareTimedOutOutput_whenFinished_thenItIsATimeoutOfSixtySeconds() async {
        // given: SYNTHETIC
        let runner = ConversationRunner { _, _ in convRaw(exit: 0, timedOut: true) }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        guard case .failure(.timedOut(_, let seconds)) = result else { Issue.record("expected timedOut, got \(result)"); return }
        #expect(seconds == 60)
    }

    @Test func givenLegacyTaskEvents_whenOutputExceedsItsOwnCap_thenItIsStillRefused() async {
        // given: SYNTHETIC; the existing 256 KiB task-events limit is unchanged
        let output = ProcessOutput(exitCode: 0, stdout: Data(repeating: 0x78, count: 262_145), stderr: "")
        let runner = ConversationRunner { _, _ in .success(output) }
        // when
        let result = await conversationClient(runner).raw("task-events", positionals: [ConvID.head])
        // then
        guard case .failure(.unreadable(_, _, let stderr)) = result else { Issue.record("expected unreadable, got \(result)"); return }
        #expect(stderr.contains("exceeded document byte limit"))
    }

    @Test func givenLegacyRaw_whenOutputExceedsConversationCap_thenItIsNotLimitedByTheConversationCap() async throws {
        // given: SYNTHETIC; raw keeps its own behaviour, so a large valid status document is not cut at 1 MiB
        var padded = try ConvFixture.data(ConvFixture.file("send-ack"))
        padded.append(Data(repeating: 0x20, count: (1 << 20) + 1 - padded.count))
        let output = ProcessOutput(exitCode: 0, stdout: padded, stderr: "")
        let runner = ConversationRunner { _, _ in .success(output) }
        // when
        let result = await conversationClient(runner).raw("status", positionals: [ConvID.head])
        // then
        guard case .success = result else { Issue.record("expected success, got \(result)"); return }
    }

    @Test func givenTargetOfAnotherTask_whenPrepared_thenResultIsUnreadable() async throws {
        // given: SYNTHETIC mutation of a fixture; no vendored fixture carries a target object
        var raw = try ConvFixture.result("empty")
        raw["target"] = .object(["kind": .string("task"), "task_id": .string("other-task")])
        let runner = ConversationRunner { _, _ in convResult(raw) }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        guard case .failure(.unreadable) = result else { Issue.record("expected unreadable, got \(result)"); return }
    }

    @Test func givenResolvedPrefix_whenPrepared_thenHeadTaskTargetIsAcceptedViaResolvedFrom() async throws {
        // given: SYNTHETIC mutation; the requested id is a prefix that resolved to the head task
        var raw = try ConvFixture.result("empty")
        raw["target"] = .object(["kind": .string("task"), "task_id": .string(ConvID.head)])
        raw["resolved_from"] = .object(["input": .string("00000000"), "task_id": .string(ConvID.head)])
        let runner = ConversationRunner { _, _ in convResult(raw) }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: "00000000")
        // then
        let projection = try result.get()
        #expect(projection.target == .task(taskID: ConvID.head))
        #expect(projection.raw["resolved_from"]?.objectValue?["input"]?.stringValue == "00000000")
    }

    @Test(arguments: [1, 2, 3])
    func givenPrepareFailsAtAnyPhase_whenCalled_thenItIsAPlainToolFailure(phase: Int) async {
        // given
        let runner = ConversationRunner(
            probe: { environment, _ in
                phase == 1 ? .success(conversationProbe(environment, productVersion: "9.9.9")) : .success(conversationProbe(environment))
            },
            command: { _, _ in phase == 2 ? .failure(.timedOut(tool: "harflow-ctl", seconds: 60)) : convRaw(exit: 0, stdout: "nope") }
        )
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        guard case .failure = result else { Issue.record("expected failure, got \(result)"); return }
    }
}
