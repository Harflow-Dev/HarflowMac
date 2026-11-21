import Foundation
import HfRepository
import MonitorCore
import SwiftEnvironment

/// Process boundary fake for hosted MainWindowFeature tests. The production repository and ctl client
/// remain in the path; only their process endpoint is synthetic.
final class WorkflowSteeringHostedEndpoint: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let rootID: String
    private var statusData: Data
    private var statusSequence = 10
    private let historyData: Data
    private var recordedActions: [String] = []
    private var recordedTexts: [String] = []
    private var recordedHistoryRequests = 0
    private let steeringGate: SteeringHostedEndpointGate?
    private let historyGate = SteeringHostedEndpointGate()

    init(
        rootID: String, status overrideStatus: WorkflowSteeringStatus? = nil,
        history overrideHistory: WorkflowSteeringHistoryPage? = nil, blockSteering: Bool = false
    ) throws {
        self.rootID = rootID
        self.steeringGate = blockSteering ? SteeringHostedEndpointGate(armed: true) : nil
        let status = try overrideStatus ?? WorkflowSteeringTestFixtures.status(
            rootID: rootID, state: "awaiting_caller", held: true, eligibleActions: ["reply", "dismiss"]
        )
        let history = try overrideHistory ?? WorkflowSteeringTestFixtures.history(rootID: rootID, items: [])
        self.statusSequence = Int(status.sequence)
        self.statusData = try WorkflowSteeringTestFixtures.ctlEnvelope(resultData: status.raw)
        self.historyData = try WorkflowSteeringTestFixtures.ctlEnvelope(resultData: history.raw)
    }

    var actions: [String] { lock.withLock { recordedActions } }
    var texts: [String] { lock.withLock { recordedTexts } }
    var historyRequests: Int { lock.withLock { recordedHistoryRequests } }

    func advanceStatus(sequence: Int) throws {
        let status = try WorkflowSteeringTestFixtures.status(
            rootID: rootID, sequence: sequence, state: "awaiting_caller", held: true,
            eligibleActions: ["reply", "dismiss"]
        )
        let data = try WorkflowSteeringTestFixtures.ctlEnvelope(resultData: status.raw)
        lock.withLock {
            statusSequence = sequence
            statusData = data
        }
    }

    func waitForSteeringRequest() async { await steeringGate?.waitForRequest() }
    func releaseSteeringRequest() async { await steeringGate?.release() }
    func blockNextHistoryPage() async { await historyGate.arm() }
    func waitForHistoryRequest() async { await historyGate.waitForRequest() }
    func releaseHistoryPage() async { await historyGate.release() }

    func run(executable _: String, arguments: [String], environment: [String: String], currentDirectory _: String?, timeout _: Double)
        async -> Result<ProcessOutput, ToolError> {
        switch arguments.first {
        case "version-info":
            return versionInfo(environment: environment)
        case "workflow-steering-status":
            return .success(ProcessOutput(exitCode: 0, stdout: lock.withLock { statusData }, stderr: ""))
        case "workflow-steering-history":
            lock.withLock { recordedHistoryRequests += 1 }
            await historyGate.holdUntilReleased()
            return .success(ProcessOutput(exitCode: 0, stdout: historyData, stderr: ""))
        case "workflow-steer":
            return await steeringReceipt(arguments: arguments)
        default:
            return .failure(.unsupportedCommand(tool: "harflow-ctl", command: arguments.first ?? "", detail: "Unexpected fixture command"))
        }
    }

    private func versionInfo(environment: [String: String]) -> Result<ProcessOutput, ToolError> {
        let stateRoot = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
        let document: [String: Any] = [
            "product": "harflow",
            "format": "harflow.version-info",
            "v": 1,
            "product_version": HarflowVersion.current,
            "component": "engine",
            "state_root": stateRoot,
            "contracts": ["ctl": ["format": "harflow.ctl", "v": 1], "setup": ["format": "harflow.setup", "v": 1],
                          "events": ["format": "harflow.event", "v": 1]],
            "capabilities": ["ctl.v1", "setup.v1", "events.v1", "workflow-steering-read.v1", "workflow-steering-orchestrator.v1"],
            "os": "darwin",
            // swiftformat:disable:next trailingCommas
            "architecture": "arm64"
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]) else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Fixture version encoding failed"))
        }
        return .success(ProcessOutput(exitCode: 0, stdout: data, stderr: ""))
    }

    private func steeringReceipt(arguments: [String]) async -> Result<ProcessOutput, ToolError> {
        guard let option = arguments.first(where: { $0.hasPrefix("--request-file=") }),
              let data = try? Data(contentsOf: URL(fileURLWithPath: String(option.dropFirst("--request-file=".count)))),
              let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = request["action"] as? String,
              let requestID = request["request_id"] as? String,
              let episodeID = request["episode_id"] as? String else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Fixture request was not readable"))
        }
        lock.withLock {
            recordedActions.append(action)
            recordedTexts.append(request["text"] as? String ?? "")
        }
        await steeringGate?.holdUntilReleased()
        let receiptSequence = lock.withLock { statusSequence + 1 }
        do {
            let status = try WorkflowSteeringTestFixtures.status(
                rootID: rootID, sequence: receiptSequence, state: "awaiting_caller", held: true,
                eligibleActions: ["reply", "dismiss"]
            )
            let data = try WorkflowSteeringTestFixtures.ctlEnvelope(resultData: status.raw)
            lock.withLock {
                statusSequence = receiptSequence
                statusData = data
            }
        } catch {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Fixture status encoding failed"))
        }
        let result: [String: Any] = [
            "accepted": true,
            "request_id": requestID,
            "episode_id": episodeID,
            "steering_revision": 2,
            "interaction_epoch": request["expected_interaction_epoch"] as? Int ?? 1,
            "control_revision": request["expected_control_revision"] as? Int ?? 1,
            "ledger_epoch": request["ledger_epoch"] as? Int ?? 1,
            "sequence": receiptSequence,
            "scheduled": false,
            "replayed": false,
            // swiftformat:disable:next trailingCommas
            "state": "queued"
        ]
        let envelope: [String: Any] = [
            "product": "harflow",
            "format": "harflow.ctl",
            "v": 1,
            "product_version": HarflowVersion.current,
            // swiftformat:disable:next trailingCommas
            "result": result
        ]
        guard let output = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else {
            return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Fixture receipt encoding failed"))
        }
        return .success(ProcessOutput(exitCode: 0, stdout: output, stderr: ""))
    }
}

private actor SteeringHostedEndpointGate {
    private var armed: Bool
    private var requestArrived = false
    private var released = false
    private var requestWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init(armed: Bool = false) { self.armed = armed }

    func holdUntilReleased() async {
        guard armed else { return }
        requestArrived = true
        requestWaiter?.resume()
        requestWaiter = nil
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func arm() {
        armed = true
        requestArrived = false
        released = false
    }

    func waitForRequest() async {
        guard !requestArrived else { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
