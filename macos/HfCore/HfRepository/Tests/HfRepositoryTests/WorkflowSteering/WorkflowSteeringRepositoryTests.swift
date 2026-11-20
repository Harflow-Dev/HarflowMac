import Combine
import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import SwiftEnvironment
import Testing

struct WorkflowSteeringRepositoryTests {
    private let root = String(repeating: "a", count: 32)

    @Test func givenCapturedObservation_whenRuntimeReturnsToSameSelection_thenOldGenerationIsRevoked() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .timeout)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let states = CurrentValueSubject<ManagedRuntimeState, Never>(.preparing)
        sut.bindRuntimeChanges(states.eraseToAnyPublisher())

        let observation = try await sut.observation(rootID: root)
        #expect(sut.isCurrent(observation))
        states.send(.failed("fixture transition"))
        states.send(.preparing)

        #expect(!sut.isCurrent(observation))
        #expect(runner.steeringActions.isEmpty)
    }

    @Test func givenUnknownAttempt_whenRuntimeChangesAndReturns_thenEvidenceRemainsIndeterminateAcrossGenerations() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .timeout)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let states = CurrentValueSubject<ManagedRuntimeState, Never>(.preparing)
        sut.bindRuntimeChanges(states.eraseToAnyPublisher())
        let observation = try await sut.observation(rootID: root)
        let attempt = try await sut.perform(action: .open, text: "start", observation: observation)
        #expect(attempt.isIndeterminate)

        states.send(.failed("selection changed"))
        states.send(.preparing)
        let retained = try #require(sut.attempts(rootID: root).first)

        #expect(retained.id == attempt.id)
        #expect(retained.isIndeterminate)
        #expect(retained.generation == observation.generation)
    }

    @Test func givenLaunchedInvocationIsCancelled_whenRunnerReturnsStructuredError_thenAttemptRemainsIndeterminate() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .cancellable)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let observation = try await sut.observation(rootID: root)
        let invocation = Task { try await sut.perform(action: .open, text: "start", observation: observation) }
        await runner.waitForSteeringCall()
        invocation.cancel()
        await runner.releaseSteeringCall()

        let attempt = try await invocation.value
        #expect(attempt.isIndeterminate)
        if case let .indeterminate(failure)? = attempt.outcome {
            #expect(!failure.definiteExit)
        } else {
            Issue.record("Expected a retained indeterminate outcome")
        }
        #expect(runner.steeringActions == ["open"])
    }

    @Test func givenDefiniteStructuredError_whenFreshStatusKeepsAllRevisionsAndSequence_thenRefusalIsEstablished() async throws {
        let (sut, runner) = try makeHarness(mode: .sourceUnavailable, audited: true)
        let initial = try await sut.observation(rootID: root)
        let attempt = try await sut.perform(action: .open, text: "start", observation: initial)
        #expect(attempt.isIndeterminate)
        #expect(!attempt.refusalEstablished)

        _ = try await sut.observation(rootID: root)

        let retained = try #require(sut.attempts(rootID: root).first)
        #expect(retained.id == attempt.id)
        #expect(retained.refusalEstablished)
        #expect(!retained.isIndeterminate)
        #expect(runner.steeringActions == ["open"])
    }

    @Test func givenDefiniteStructuredError_whenFreshSequenceMoves_thenOutcomeStaysIndeterminate() async throws {
        let (sut, runner) = try makeHarness(mode: .sourceUnavailable, audited: true)
        let initial = try await sut.observation(rootID: root)
        let attempt = try await sut.perform(action: .open, text: "start", observation: initial)
        runner.advanceSequence()

        let moved = try await sut.observation(rootID: root)

        #expect(moved.status.sequence > initial.status.sequence)
        #expect(sut.attempts(rootID: root).first?.refusalEstablished == false)
        #expect(sut.attempts(rootID: root).first?.isIndeterminate == true)
        #expect(runner.steeringActions == ["open"])
        #expect(attempt.isIndeterminate)
    }

    @Test func givenUnchangedStatusEstablishesRefusal_whenOwnerMakesNewDismiss_thenUsesIndependentRequestIdentity() async throws {
        let (sut, runner) = try makeHarness(mode: .sourceUnavailableStableEpisode, audited: true)
        let initial = try await sut.observation(rootID: root)
        let first = try await sut.perform(action: .reply, text: "answer", observation: initial)
        let refreshed = try await sut.observation(rootID: root)
        #expect(sut.attempts(rootID: root).first?.refusalEstablished == true)

        let dismiss = try await sut.perform(action: .dismiss, text: nil, observation: refreshed)

        #expect(dismiss.request.requestID != first.request.requestID)
        #expect(runner.requestIDs.count == 2)
        #expect(runner.requestIDs[0] != runner.requestIDs[1])
        #expect(runner.steeringActions == ["reply", "dismiss"])
    }

    @Test func givenSameScalarStatusWithNewHeldEpisode_whenCheckingDefiniteRefusal_thenContradictionStaysUnknown() async throws {
        let (sut, runner) = try makeHarness(mode: .sourceUnavailable, audited: true, heldAfterInvocation: true)
        let initial = try await sut.observation(rootID: root)
        let attempt = try await sut.perform(action: .open, text: "start", observation: initial)

        let after = try await sut.observation(rootID: root)

        #expect(after.status.sequence == initial.status.sequence)
        #expect(after.status.interactionEpoch == initial.status.interactionEpoch)
        #expect(after.status.controlRevision == initial.status.controlRevision)
        #expect(after.status.episodes != initial.status.episodes)
        #expect(sut.attempts(rootID: root).first?.refusalEstablished == false)
        #expect(sut.attempts(rootID: root).first?.isIndeterminate == true)
        #expect(runner.steeringActions == ["open"])
        #expect(attempt.isIndeterminate)
    }

    @Test func givenUnknownSend_whenOwnerAuthorizesDismiss_thenBothInvocationsRemainSeparateAndNoReplayOccurs() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .timeout)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)

        let firstObservation = try await sut.observation(rootID: root)
        let send = try await sut.perform(action: .open, text: "start", observation: firstObservation)
        #expect(send.isIndeterminate)
        let heldObservation = try await sut.observation(rootID: root)
        let dismiss = try await sut.perform(action: .dismiss, text: nil, observation: heldObservation)

        #expect(dismiss.isIndeterminate)
        #expect(sut.attempts(rootID: root).map(\.request.action) == [.open, .dismiss])
        #expect(runner.steeringActions == ["open", "dismiss"])
        #expect(sut.attempts(rootID: root).first?.isIndeterminate == true)

        let stillFenced = try await sut.observation(rootID: root)
        var unresolved = false
        do {
            _ = try await sut.perform(action: .reply, text: "answer", observation: stillFenced)
        } catch WorkflowSteeringAdmissionError.unresolved {
            unresolved = true
        }
        #expect(unresolved)
        #expect(runner.steeringActions == ["open", "dismiss"])
    }

    @Test func givenUnresolvedDismissForEpisode_whenSameEpisodeIsShownAgain_thenDismissIsNotRepeated() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .sameEpisodeTimeout)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let initial = try await sut.observation(rootID: root)
        _ = try await sut.perform(action: .open, text: "start", observation: initial)
        let held = try await sut.observation(rootID: root)
        _ = try await sut.perform(action: .dismiss, text: nil, observation: held)
        let sameHeld = try await sut.observation(rootID: root)

        var unresolved = false
        do {
            _ = try await sut.perform(action: .dismiss, text: nil, observation: sameHeld)
        } catch WorkflowSteeringAdmissionError.unresolved {
            unresolved = true
        }

        #expect(unresolved)
        #expect(runner.steeringActions == ["open", "dismiss"])
    }

    @Test func givenResolvedSchemaTwoSends_whenFreshStatusesConsumeEachReceipt_thenAttemptCapacityIsReused() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .admit)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)

        for _ in 0 ..< 260 {
            let observation = try await sut.observation(rootID: root)
            let attempt = try await sut.perform(action: .open, text: "start", observation: observation)
            #expect(attempt.isAdmitted)
        }

        #expect(runner.steeringActions.count == 260)
        #expect(sut.attempts(rootID: root).count == 1)
    }

    @Test func givenAdmittedRequest_whenFreshStatusAdvancesSchemaTwoLedger_thenNewRequestUsesAdvancedEpoch() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .ledgerAdvanceAdmit)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let initial = try await sut.observation(rootID: root)
        let first = try await sut.perform(action: .open, text: "start", observation: initial)
        let after = try await sut.observation(rootID: root)
        let second = try await sut.perform(action: .open, text: "start again", observation: after)

        #expect(first.isAdmitted)
        #expect(after.status.ledgerEpoch == 2)
        #expect(second.isAdmitted)
        #expect(runner.requestLedgerEpochs == [1, 2])
    }

    @Test func givenRootLeaseIsEvicted_whenOtherRootsAreObserved_thenInvocationEvidenceRemains() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .timeout)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let observation = try await sut.observation(rootID: root)
        let attempt = try await sut.perform(action: .open, text: "start", observation: observation)
        #expect(attempt.isIndeterminate)

        for index in 1 ... 128 {
            let otherRoot = String(format: "%032x", index)
            _ = try await sut.observation(rootID: otherRoot)
        }

        #expect(!sut.isCurrent(observation))
        #expect(sut.attempts(rootID: root).map(\.id) == [attempt.id])
    }

    @Test func givenUnresolvedDismissAttemptsFillBoundedEvidence_whenCapacityIsReached_thenNoFurtherInvocationDispatches() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .timeout)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let first = try await sut.observation(rootID: root)
        _ = try await sut.perform(action: .open, text: "start", observation: first)

        var capacityRefused = false
        for _ in 0 ..< 40 {
            let observation = try await sut.observation(rootID: root)
            do {
                _ = try await sut.perform(action: .dismiss, text: nil, observation: observation)
            } catch WorkflowSteeringAdmissionError.capacity {
                capacityRefused = true
                break
            }
        }

        #expect(capacityRefused)
        #expect(runner.steeringActions.count == sut.attempts(rootID: root).count)
        let attempts = sut.attempts(rootID: root)
        let allIndeterminate = attempts.allSatisfy(\.isIndeterminate)
        #expect(allIndeterminate)
    }

    @Test func givenTimedOutInvocationAndMatchingRequestedHistory_whenReconciled_thenAdmissionIsPositiveEvenWithGap() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .historyProof)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let initial = try await sut.observation(rootID: root)
        let attempt = try await sut.perform(action: .open, text: "start", observation: initial)
        runner.advanceSequence()
        let after = try await sut.observation(rootID: root)

        _ = try await sut.history(observation: after, cursor: nil)

        let reconciled = try #require(sut.attempts(rootID: root).first)
        #expect(reconciled.id == attempt.id)
        #expect(reconciled.isAdmitted)
        #expect(!reconciled.isIndeterminate)
        #expect(reconciled.admissionHistory?.requestID == attempt.request.requestID)
    }

    @Test func givenMismatchedHistoryText_whenReconcilingUnknownAttempt_thenFenceRemains() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .mismatchedHistory)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let initial = try await sut.observation(rootID: root)
        _ = try await sut.perform(action: .open, text: "start", observation: initial)
        runner.advanceSequence()
        let after = try await sut.observation(rootID: root)

        _ = try await sut.history(observation: after, cursor: nil)

        let retained = try #require(sut.attempts(rootID: root).first)
        #expect(retained.admissionHistory == nil)
        #expect(retained.isIndeterminate)
    }

    @Test func givenRuntimeAbaDuringCompatibilityHandshake_whenObservationCompletes_thenOldReadIsRejected() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .handshakeSuspended)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let states = CurrentValueSubject<ManagedRuntimeState, Never>(.preparing)
        sut.bindRuntimeChanges(states.eraseToAnyPublisher())
        let read = Task { try await sut.observation(rootID: root) }
        await runner.waitForHandshake()
        states.send(.failed("runtime transition"))
        states.send(.preparing)
        await runner.releaseHandshake()

        let observation = try? await read.value
        #expect(observation == nil)
        #expect(runner.statusReadCount == 0)
    }

    @Test func givenStatusReadOverlapsCommandSettlement_whenReadCompletes_thenItCannotPublishAsCurrent() async throws {
        let runner = SteeringRepositoryTestRunner(mode: .overlapSuspended)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let sut = WorkflowSteeringRepositoryImpl(tooling: tooling)
        let initial = try await sut.observation(rootID: root)
        let invocation = Task { try await sut.perform(action: .open, text: "start", observation: initial) }
        await runner.waitForSteeringCall()
        let overlappingRead = Task { try await sut.observation(rootID: root) }
        await runner.waitForOverlappingStatusRead()

        await runner.releaseSteeringCall()
        let attempt = try await invocation.value
        #expect(attempt.isIndeterminate)
        await runner.releaseOverlappingStatusRead()

        let staleObservation = try? await overlappingRead.value
        #expect(staleObservation == nil)
        #expect(runner.steeringActions == ["open"])
    }
}

private final class SteeringRepositoryTestRunner: ProcessRunning, @unchecked Sendable {
    enum Mode: Equatable {
        case admit, ledgerAdvanceAdmit, timeout, sameEpisodeTimeout, sourceUnavailable, sourceUnavailableStableEpisode, cancellable
        case historyProof, mismatchedHistory, handshakeSuspended
        case overlapSuspended
    }

    private let lock = NSLock()
    private let mode: Mode
    private let heldAfterInvocation: Bool
    private var _calls: [[String]] = []
    private var _actions: [String] = []
    private var _statusReads = 0
    private var _sequence = 10
    private var _requestIDs: [String] = []
    private var _requestLedgerEpochs: [Int] = []
    private var _requestObject: [String: Any]?
    private var _ledgerEpoch = 1
    private let steeringGate = SteeringRepositoryCallGate()
    private let handshakeGate = SteeringRepositoryCallGate()
    private let statusGate = SteeringRepositoryCallGate()

    init(mode: Mode, heldAfterInvocation: Bool = false) {
        self.mode = mode
        self.heldAfterInvocation = heldAfterInvocation
    }

    var steeringActions: [String] { lock.withLock { _actions } }
    var requestIDs: [String] { lock.withLock { _requestIDs } }
    var requestLedgerEpochs: [Int] { lock.withLock { _requestLedgerEpochs } }
    var statusReadCount: Int { lock.withLock { _statusReads } }

    func advanceSequence() { lock.withLock { _sequence += 1 } }
    func waitForSteeringCall() async { await steeringGate.waitUntilEntered() }
    func releaseSteeringCall() async { await steeringGate.release() }
    func waitForHandshake() async { await handshakeGate.waitUntilEntered() }
    func releaseHandshake() async { await handshakeGate.release() }
    func waitForOverlappingStatusRead() async { await statusGate.waitUntilEntered() }
    func releaseOverlappingStatusRead() async { await statusGate.release() }

    func run(executable _: String, arguments: [String], environment: [String: String], currentDirectory _: String?, timeout _: Double)
        async -> Result<ProcessOutput, ToolError> {
        lock.withLock { _calls.append(arguments) }
        if arguments == ["version-info", "--json"] { return await versionInfo(environment: environment) }
        if arguments.first == "workflow-steering-status" { return await status(arguments: arguments) }
        if arguments.first == "workflow-steering-history" { return .success(history(arguments: arguments)) }
        if arguments.first == "workflow-steer" { return await steer(arguments: arguments) }
        return .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: ""))
    }

    private func versionInfo(environment: [String: String]) async -> Result<ProcessOutput, ToolError> {
        if mode == .handshakeSuspended { await handshakeGate.pause() }
        let stateRoot = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
        let object: [String: Any] = ["product": "harflow", "format": "harflow.version-info", "v": 1,
            "product_version": HarflowVersion.current, "component": "engine", "state_root": stateRoot,
            "contracts": ["ctl": ["format": "harflow.ctl", "v": 1], "setup": ["format": "harflow.setup", "v": 1],
                          "events": ["format": "harflow.event", "v": 1]],
            "capabilities": ["ctl.v1", "setup.v1", "events.v1", "workflow-steering-read.v1", "workflow-steering-orchestrator.v1"],
            "os": "darwin", "architecture": "arm64"]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return .success(ProcessOutput(exitCode: 0, stdout: data, stderr: ""))
    }

    private func status(arguments: [String]) async -> Result<ProcessOutput, ToolError> {
        let (held, sequence, ordinal) = lock.withLock { () -> (Bool, Int, Int) in
            _statusReads += 1
            let hold = mode == .sourceUnavailableStableEpisode || (![.admit, .ledgerAdvanceAdmit].contains(mode) && _statusReads > 1
                && (heldAfterInvocation || mode != .sourceUnavailable))
            return (hold, _sequence, _statusReads)
        }
        if mode == .overlapSuspended, ordinal > 1 { await statusGate.pause() }
        let rootID = arguments.last ?? ""
        return .success(ProcessOutput(exitCode: 0, stdout: status(rootID: rootID, held: held, sequence: sequence, ordinal: ordinal), stderr: ""))
    }

    private func history(arguments: [String]) -> ProcessOutput {
        let (request, sequence) = lock.withLock { (_requestObject ?? [:], _sequence) }
        let requestID = request["request_id"] as? String ?? ""
        let text = mode == .mismatchedHistory ? "different" : request["text"] as? String ?? ""
        let rootID = arguments.last ?? ""
        let item: [String: Any] = ["sequence": sequence, "kind": "requested", "action": "open",
            "request_id": requestID, "episode_id": String(repeating: "d", count: 32),
            "turn_id": NSNull(), "outcome": NSNull(), "text": text]
        let result: [String: Any] = ["root_workflow_run_id": rootID, "items": [item], "has_more": false,
            "next_cursor": NSNull(), "gap": true, "history_incomplete": true]
        return ProcessOutput(exitCode: 0, stdout: encode(result), stderr: "")
    }

    private func steer(arguments: [String]) async -> Result<ProcessOutput, ToolError> {
        if let option = arguments.first(where: { $0.hasPrefix("--request-file=") }) {
            let path = String(option.dropFirst("--request-file=".count))
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let action = object["action"] as? String {
                lock.withLock {
                    _actions.append(action)
                    _requestObject = object
                    if let requestID = object["request_id"] as? String { _requestIDs.append(requestID) }
                }
                if mode == .admit || mode == .ledgerAdvanceAdmit { return .success(receipt(request: object)) }
                if mode == .cancellable || mode == .overlapSuspended {
                    await steeringGate.pause()
                    return .success(sourceUnavailableOutput())
                }
                if mode == .sourceUnavailable || mode == .sourceUnavailableStableEpisode { return .success(sourceUnavailableOutput()) }
            }
        }
        if mode == .timeout || mode == .historyProof || mode == .mismatchedHistory {
            return .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: "fixture timeout", timedOut: true))
        }
        return .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: ""))
    }

    private func status(rootID: String, held: Bool, sequence: Int, ordinal: Int) -> Data {
        let target: [String: Any] = ["root_workflow_run_id": rootID, "workflow_run_id": rootID, "path": [rootID],
            "role": "orchestrator", "checkpoint_revision": 1, "goal_revision": 2, "interaction_epoch": 3,
            "control_revision": 4, "assignment_revision": NSNull(), "draft_revision": NSNull(),
            "source_revision": NSNull(), "activation_id": NSNull(), "assignment_digest": NSNull(),
            "decision_id": NSNull(), "definition_digest": NSNull(), "node_id": NSNull(), "preview_hash": NSNull(),
            "source_definition_digest": NSNull(), "source_workflow_id": NSNull(), "task_id": NSNull(), "token_id": NSNull()]
        let episodeID = if mode == .historyProof || mode == .mismatchedHistory || mode == .sourceUnavailableStableEpisode {
            String(repeating: "d", count: 32)
        } else if mode == .sameEpisodeTimeout {
            String(repeating: "c", count: 32)
        } else {
            String(format: "%032x", ordinal)
        }
        let episodes: [[String: Any]] = held ? [["episode_id": episodeID, "steering_revision": 6,
            "state": "awaiting_caller", "hold": true, "target": target]] : []
        let ledgerEpoch = lock.withLock { _ledgerEpoch }
        let result: [String: Any] = ["root_workflow_run_id": rootID, "steering_version": 1,
            "request_schema_version": 2, "ledger_epoch": ledgerEpoch, "interaction_epoch": 3, "control_revision": 4,
            "sequence": sequence, "owner": "monitor", "eligible_actions": ["open", "reply", "retarget", "dismiss"],
            "targets": [target], "episodes": episodes]
        return encode(result)
    }

    private func receipt(request: [String: Any]) -> ProcessOutput {
        let (sequence, ledgerEpoch) = lock.withLock { () -> (Int, Int) in
            _sequence += 1
            let currentLedger = _ledgerEpoch
            if mode == .ledgerAdvanceAdmit { _ledgerEpoch += 1 }
            if let ledger = request["ledger_epoch"] as? Int { _requestLedgerEpochs.append(ledger) }
            return (_sequence, currentLedger)
        }
        let result: [String: Any] = ["accepted": true, "request_id": request["request_id"] as? String ?? "",
            "episode_id": String(repeating: "d", count: 32), "steering_revision": 7,
            "interaction_epoch": request["expected_interaction_epoch"] as? Int ?? 3,
            "control_revision": request["expected_control_revision"] as? Int ?? 4, "ledger_epoch": ledgerEpoch,
            "sequence": sequence, "scheduled": false, "replayed": false, "state": "pending"]
        return ProcessOutput(exitCode: 0, stdout: encode(result), stderr: "")
    }

    private func sourceUnavailableOutput() -> ProcessOutput {
        let error: [String: Any] = ["code": "steering_source_unavailable", "message": "fixture source unavailable",
                                    "data": [String: Any]()]
        let document: [String: Any] = ["product": "harflow", "format": "harflow.ctl", "v": 1,
            "product_version": "0.0.14", "error": error]
        let output = (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) ?? Data()
        return ProcessOutput(exitCode: 2, stdout: output, stderr: "fixture source unavailable")
    }

    private func encode(_ value: [String: Any]) -> Data {
        var result = value
        if result["product"] == nil {
            result = ["product": "harflow", "format": "harflow.ctl", "v": 1,
                      "product_version": HarflowVersion.current, "result": value]
        }
        return (try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])) ?? Data()
    }
}

private actor SteeringRepositoryCallGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var parked: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        if !released { await withCheckedContinuation { parked = $0 } }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        parked?.resume()
        parked = nil
    }
}

private func makeHarness(mode: SteeringRepositoryTestRunner.Mode, audited: Bool = false, heldAfterInvocation: Bool = false) throws ->
    (WorkflowSteeringRepositoryImpl, SteeringRepositoryTestRunner) {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("steering-repository-runtime-\(UUID().uuidString)")
    let environment = audited ? ["HOME": home.path] : [:]
    let executable: String
    if audited {
        let specification = try ManagedRuntimeSpecification.bundled()
        let layout = ManagedRuntimeLayout(home: home.path)
        executable = layout.generationsDirectory + "/0.0.14-\(specification.identity)-\(UUID().uuidString.lowercased())/bin/harflow-ctl"
    } else {
        executable = "/fixture/ctl"
    }
    let runner = SteeringRepositoryTestRunner(mode: mode, heldAfterInvocation: heldAfterInvocation)
    let client = CtlClient(executable: executable, environment: environment, runner: runner)
    let tooling = MockToolEnvironmentRepository()
    given(tooling).ctl().willReturn(.success(client))
    return (WorkflowSteeringRepositoryImpl(tooling: tooling), runner)
}
