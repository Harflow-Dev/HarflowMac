import Foundation
@testable import MonitorCore
import Testing

// MARK: - Identifiers used by the vendored conversation fixtures

enum ConvID {
    static let conversation = "00000000-0000-0000-0000-000000000001"
    static let head = "00000000-0000-0000-0000-00000000000a"
    static let turn = "00000000-0000-0000-0000-00000000000b"
    static let message = "00000000-0000-0000-0000-000000000065"
    static let second = "00000000-0000-0000-0000-000000000066"
    static let third = "00000000-0000-0000-0000-000000000067"
    static let cancel = "00000000-0000-0000-0000-0000000000c9"
    static let promote = "00000000-0000-0000-0000-0000000000ca"
    static let run = "00000000-0000-0000-0000-000000000014"
    static let activation = "00000000-0000-0000-0000-000000000015"
    static let absent = "00000000-0000-0000-0000-0000000000ff"

    static func uuid(_ text: String) -> UUID { UUID(uuidString: text) ?? UUID() }
}

// MARK: - Fixture access

/// Reads the vendored `ctl-conversation-*` fixtures. Everything read here is a synthetic engine
/// output recorded by the contract owner (the manifest says `runtime_qualification: false`); none
/// of it is live engine evidence.
enum ConvFixture {
    static let prefix = "ctl-conversation-"

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ContractsV1"))
        return try Data(contentsOf: url)
    }

    static func file(_ stem: String) -> String { prefix + stem + ".json" }

    static func manifest() throws -> [String: JSONValue] {
        try #require(JSONValue.parse(data("manifest.json"))?.objectValue)
    }

    static func manifestCase(_ stem: String) throws -> [String: JSONValue] {
        try #require(manifest()["cases"]?.objectValue?[file(stem)]?.objectValue)
    }

    static func exitCode(_ stem: String) throws -> Int32 {
        Int32(try #require(manifestCase(stem)["exit_code"]?.intValue))
    }

    static func document(_ stem: String) throws -> [String: JSONValue] {
        try #require(JSONValue.parse(data(file(stem)))?.objectValue)
    }

    static func result(_ stem: String) throws -> [String: JSONValue] {
        try #require(document(stem)["result"]?.objectValue)
    }

    static func projection(_ stem: String) throws -> ConversationDeliveryProjection {
        try #require(ConversationDeliveryProjection(raw: result(stem)))
    }

    /// Fixture file names listed by the manifest.
    static func manifestNames() throws -> Set<String> {
        Set(try #require(manifest()["cases"]?.objectValue).keys.filter { $0.hasPrefix(prefix) })
    }

    /// Fixture file names actually bundled with the test target.
    static func bundledNames() -> Set<String> {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "ContractsV1") ?? []
        return Set(urls.map(\.lastPathComponent).filter { $0.hasPrefix(prefix) })
    }

    /// The fixture exactly as the engine printed it, with the exit code the manifest records.
    static func output(_ stem: String) -> Result<ProcessOutput, ToolError> {
        do {
            return .success(ProcessOutput(exitCode: try exitCode(stem), stdout: try data(file(stem)), stderr: ""))
        } catch {
            return .failure(.unreadable(tool: "fixture", exitCode: 0, stderr: "\(error)"))
        }
    }
}

// MARK: - Synthetic process output

/// Builds a `harflow-ctl` version-info answer. Not engine output: a synthetic stand-in.
func conversationProbe(_ environment: [String: String], capability: Bool = true, productVersion: String = HarflowVersion.current,
                       extraCapabilities: [String] = []) -> ProcessOutput {
    let root = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
    let capabilities = ["ctl.v1", "setup.v1", "events.v1"] + (capability ? [CtlCapability.conversationDelivery] : []) + extraCapabilities
    let raw: [String: JSONValue] = [
        "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
        "product_version": .string(productVersion), "component": .string("engine"), "state_root": .string(root),
        "contracts": .object([
            "ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
            "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
            "events": .object(["format": .string("harflow.event"), "v": .number(1)])
        ]),
        "capabilities": .array(capabilities.map(JSONValue.string)),
        "os": .string("darwin"), "architecture": .string("arm64")
    ]
    return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
}

typealias ConvResult = Result<ProcessOutput, ToolError>

/// A synthetic ctl document with the current envelope stamped on.
func convDocument(_ body: [String: JSONValue], exit: Int32) -> ConvResult {
    .success(ProcessOutput(exitCode: exit, stdout: ctlJSON(JSONValue.object(body).rendered()), stderr: ""))
}

func convResult(_ raw: [String: JSONValue], exit: Int32 = 0) -> ConvResult {
    convDocument(["result": .object(raw)], exit: exit)
}

func convError(code: String, message: String? = nil, data: JSONValue? = nil, exit: Int32 = 1) -> ConvResult {
    var error: [String: JSONValue] = ["code": .string(code), "message": .string(message ?? code)]
    if let data { error["data"] = data }
    return convDocument(["error": .object(error)], exit: exit)
}

func convRaw(exit: Int32, stdout: String = "", stderr: String = "", timedOut: Bool = false) -> ConvResult {
    .success(ProcessOutput(exitCode: exit, stdout: Data(stdout.utf8), stderr: stderr, timedOut: timedOut))
}

// MARK: - Scripted runner

/// Records every call and answers the version probe and the operation separately, so a test can
/// script a failure at one phase. Unlike `RecordingRunner` it can return a runner failure.
final class ConversationRunner: ProcessRunning, @unchecked Sendable {
    typealias Probe = @Sendable ([String: String], Int) -> ConvResult
    typealias Command = @Sendable ([String], Int) async -> ConvResult

    private let lock = NSLock()
    private var calls: [[String]] = []
    private var timeouts: [Double] = []
    private var invocations: [(String, [String: String])] = []
    private var probes = 0
    private var commands = 0
    private let probe: Probe
    private let command: Command

    init(probe: @escaping Probe = { environment, _ in .success(conversationProbe(environment)) },
         command: @escaping Command) {
        self.probe = probe
        self.command = command
    }

    var runtimeCalls: [(String, [String: String])] { lock.withLock { invocations } }
    var allCalls: [[String]] { lock.withLock { calls } }
    var commandCalls: [[String]] { allCalls.filter { $0 != ["version-info", "--json"] } }
    var probeCount: Int { lock.withLock { probes } }
    var commandTimeouts: [Double] { lock.withLock { timeouts } }

    func run(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?,
             timeout: Double) async -> Result<ProcessOutput, ToolError> {
        lock.withLock { invocations.append((executable, environment)) }
        if arguments == ["version-info", "--json"] {
            let index = lock.withLock { () -> Int in
                probes += 1
                calls.append(arguments)
                return probes
            }
            return probe(environment, index)
        }
        let index = lock.withLock { () -> Int in
            commands += 1
            calls.append(arguments)
            timeouts.append(timeout)
            return commands
        }
        return await command(arguments, index)
    }
}

func conversationClient(_ runner: ConversationRunner) -> CtlClient {
    CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
}

// MARK: - Request file observation

/// What a request file looked like at the moment the command ran.
struct RequestFileSnapshot: Equatable, Sendable {
    let path: String
    let fileMode: Int?
    let directoryMode: Int?
    let body: Data?
    let directoryName: String
}

func snapshotRequestFile(_ arguments: [String]) -> RequestFileSnapshot {
    let path = arguments.last ?? ""
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    let manager = FileManager.default
    let fileMode = (try? manager.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    let directoryMode = (try? manager.attributesOfItem(atPath: directory.path))?[.posixPermissions] as? Int
    return RequestFileSnapshot(path: path, fileMode: fileMode, directoryMode: directoryMode,
                               body: try? Data(contentsOf: url), directoryName: directory.lastPathComponent)
}

/// Collects values from `@Sendable` runner closures.
final class Collector<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Element] = []
    var values: [Element] { lock.withLock { storage } }
    func add(_ value: Element) { lock.withLock { storage.append(value) } }
}

// MARK: - Request builders

func convWitness(generation: Int = 1, epoch: Int = 0, conversation: String = ConvID.conversation) throws -> ConversationDeliveryWitness {
    try ConversationDeliveryWitness(conversationID: conversation, headTaskID: ConvID.head, generation: generation,
                                    turnID: ConvID.turn, ledgerEpoch: epoch)
}

func convSend(id: String = ConvID.message, text: String = "Keep  two spaces.\nFollow-up prose stays verbatim.",
              mode: ConversationDeliveryMode = .queue,
              target: ConversationDeliveryTarget = .task(taskID: ConvID.head)) throws -> ConversationDeliverySendRequest {
    try ConversationDeliverySendRequest(requestID: ConvID.uuid(id), witness: convWitness(), target: target, mode: mode, text: text)
}

func convControl(id: String = ConvID.cancel, operation: ConversationDeliveryControlOperation = .cancel,
                 message: String = ConvID.message,
                 target: ConversationDeliveryTarget = .task(taskID: ConvID.head)) throws -> ConversationDeliveryControlRequest {
    try ConversationDeliveryControlRequest(requestID: ConvID.uuid(id), operation: operation, messageRequestID: ConvID.uuid(message),
                                           witness: convWitness(), target: target)
}

let convWorkflowTarget = ConversationDeliveryTarget.workflowActivation(
    workflowRunID: ConvID.run, activationID: ConvID.activation, taskID: ConvID.head)

// MARK: - Outcome inspection

extension ConversationDeliveryOutcome {
    /// The request carried by any non-accepted case.
    var carriedRequest: Request? {
        switch self {
        case .accepted: nil
        case .notDispatched(let request, _): request
        case .engineError(let request, _): request
        case .uncertain(let request, _): request
        }
    }

    var isAccepted: Bool {
        if case .accepted = self { return true }
        return false
    }
}

/// Parses a request file body back to an object, so tests assert wire shape and not just bytes.
func decodedBody(_ data: Data) throws -> [String: JSONValue] {
    try #require(JSONValue.parse(data)?.objectValue)
}
