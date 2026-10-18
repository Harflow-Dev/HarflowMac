import Foundation
@testable import MonitorCore
import Testing

@Suite(.serialized)
struct CompatibilityClientTests {
    private let home = "/tmp/harflow-fixture-home"
    private var root: String { home + "/.harflow" }

    private func versionInfo(
        root: String? = nil,
        product: String = "harflow",
        format: String = "harflow.version-info",
        version: String = "1.0.0",
        wireVersion: String = "1",
        operatingSystem: String = "darwin",
        architecture: String = "arm64",
        capabilities: [String] = ["ctl.v1", "setup.v1", "events.v1", "version-info.v1"],
        contracts: String = #""ctl":{"format":"harflow.ctl","v":1},"setup":{"format":"harflow.setup","v":1},"events":{"format":"harflow.event","v":1}"#,
        suffix: String = ""
    ) -> Data {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        let value = root ?? self.root
        return json("""
        {"product":"\(product)","format":"\(format)","v":\(wireVersion),"product_version":"\(version)","component":"engine","state_root":"\(value)",
        "contracts":{\(contracts)},"capabilities":[\(caps)],"os":"\(operatingSystem)","architecture":"\(architecture)"}\(suffix)
        """)
    }

    private func ctlSuccess() -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdout: json("""
        {"product":"harflow","format":"harflow.ctl","v":1,"product_version":"1.0.0","tasks":[]}
        """), stderr: "")
    }

    private func setupSuccess() -> ProcessOutput {
        ProcessOutput(exitCode: 0, stdout: json("""
        {"product":"harflow","format":"harflow.setup","v":1,"product_version":"1.0.0","clients":[]}
        """), stderr: "")
    }

    private func client(_ runner: RecordingRunner) -> CtlClient {
        CtlClient(executable: "/runtime/harflow-ctl", environment: ["HOME": home, "HARFLOW_OPEN_MONITOR": "0"], runner: runner)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ContractsV1"))
        return try Data(contentsOf: url)
    }

    @Test
    func givenInvalidVersionInfo_whenListing_thenNoRequestedCommandLaunches() async {
        let invalid: [(String, Data)] = [
            ("wrong root", versionInfo(root: "/tmp/other/.harflow")),
            ("wrong os", versionInfo(operatingSystem: "linux")),
            ("wrong architecture", versionInfo(architecture: "x86_64")),
            ("missing capability", versionInfo(capabilities: ["setup.v1", "events.v1", "version-info.v1"])),
            ("missing contract", versionInfo(contracts: #""setup":{"format":"harflow.setup","v":1},"events":{"format":"harflow.event","v":1}"#)),
            ("foreign legacy", json("{\"v\":14,\"tasks\":[]}")),
            ("multiple documents", versionInfo() + json("\n{}")),
            ("oversized", versionInfo() + Data(repeating: 0x20, count: VersionInfoDocument.maximumBytes))
        ]

        let baseline = VersionInfoDocument.decode(
            stdout: versionInfo(), context: RuntimeCompatibilityContext(expectedStateRoot: root), requiring: [.ctl]
        )
        guard case .success = baseline else {
            Issue.record("baseline version-info fixture must decode before negative cases")
            return
        }

        for (name, answer) in invalid {
            if name != "foreign legacy", name != "multiple documents", name != "oversized" {
                #expect(JSONValue.parse(answer)?.objectValue != nil, "negative fixture must remain valid JSON: \(name)")
            }
            let runner = RecordingRunner { call in
                if call.arguments == ["version-info", "--json"] {
                    return ProcessOutput(exitCode: 0, stdout: answer, stderr: "")
                }
                Issue.record("requested command launched for \(name): \(call.arguments)")
                return ctlSuccess()
            }
            let result = await client(runner).list()
            guard case .failure = result else { Issue.record("expected \(name) to fail"); continue }
            #expect(runner.calls.isEmpty)
            #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"]])
        }
    }

    @Test
    func givenBooleanOrFloatWireVersion_whenProbing_thenCompatibilityFailsClosed() async {
        for wireVersion in ["true", "1.0"] {
            let runner = RecordingRunner { _ in
                ProcessOutput(exitCode: 0, stdout: versionInfo(wireVersion: wireVersion), stderr: "")
            }
            let result = await client(runner).checkCompatibility()
            guard case .failure = result else { Issue.record("expected \(wireVersion) to be rejected"); continue }
            #expect(runner.calls.isEmpty)
        }
    }

    @Test
    func givenUnknownAdditiveCapability_whenProbing_thenKnownRequirementsStillPass() {
        let result = VersionInfoDocument.decode(
            stdout: versionInfo(capabilities: ["ctl.v1", "setup.v1", "events.v1", "version-info.v1", "future.v9"]),
            context: RuntimeCompatibilityContext(expectedStateRoot: root), requiring: [.ctl]
        )
        guard case .success(let document) = result else {
            Issue.record("unknown additive capabilities should be tolerated")
            return
        }
        #expect(document.capabilities.contains("future.v9"))
    }

    @Test
    func givenCanonicalNegativeInnerEvent_whenDecodedAsEventPage_thenForeignNestedIdentityFails() throws {
        let result = CtlDocument.decodeEventPage(stdout: try fixture("invalid-ctl-inner-event.json"))
        guard case .failure = result else {
            Issue.record("foreign nested event identity must fail event-page decoding")
            return
        }
    }

    @Test
    func givenCanonicalUsageFixtures_whenDecoded_thenCommonEnvelopePrecedesUsageSemantics() throws {
        let ctl = CtlDocument.decode(
            stdout: try fixture("ctl-usage.json"), stderr: "", exitCode: 2, command: "list"
        )
        guard case .success(.error(let code, let message)) = ctl else {
            Issue.record("expected ctl usage fixture to remain a structured error: \(ctl)")
            return
        }
        #expect(code == "usage")
        #expect(message.contains("required: command"))

        let setup = SetupDocument.decode(stdout: try fixture("setup-usage.json"), stderr: "", exitCode: 2)
        guard case .failure(.refused(let code, _)) = setup else {
            Issue.record("expected setup usage fixture to remain a structured refusal: \(setup)")
            return
        }
        #expect(code == "usage")
    }

    @Test
    func givenTwoOperations_whenRuntimeIsValid_thenEachOperationGetsAnUncachedProbe() async throws {
        let runner = compatibleRunner { _ in ctlSuccess() }
        let client = client(runner)
        guard case .success = await client.list(), case .success = await client.list() else {
            Issue.record("valid runtime and ctl response should allow both operations")
            return
        }
        #expect(runner.allCalls.map(\.arguments) == [
            ["version-info", "--json"], ["list", "--json"],
            ["version-info", "--json"], ["list", "--json"]
        ])
    }

    @Test
    func givenValidProbe_whenCtlResponseIsForeignOrIncompatible_thenResponseFailsIndependently() async {
        let answers: [Data] = [
            json("{\"product\":\"polybridge\",\"format\":\"harflow.ctl\",\"v\":1,\"product_version\":\"1.0.0\",\"tasks\":[]}"),
            json("{\"product\":\"harflow\",\"format\":\"harflow.setup\",\"v\":1,\"product_version\":\"1.0.0\",\"tasks\":[]}"),
            json("{\"product\":\"harflow\",\"format\":\"harflow.ctl\",\"v\":1,\"product_version\":\"1.1.0\",\"tasks\":[]}")
        ]
        for answer in answers {
            let runner = compatibleRunner { _ in ProcessOutput(exitCode: 0, stdout: answer, stderr: "") }
            let result = await client(runner).list()
            guard case .failure = result else { Issue.record("expected live response validation failure"); continue }
            #expect(runner.calls.count == 1)
        }
    }

    @Test
    func givenCustomAndBatchCommands_whenCalled_thenBothRemainBehindTheProbe() async {
        let runner = compatibleRunner { call in
            if call.arguments.first == "status-batch" {
                return ProcessOutput(exitCode: 0, stdout: json("""
                {"product":"harflow","format":"harflow.ctl","v":1,"product_version":"1.0.0","tasks":[],"errors":{}}
                """), stderr: "")
            }
            return ctlSuccess()
        }
        let client = client(runner)
        guard case .success = await client.statusBatch(ids: ["one"]), case .success = await client.raw("custom-command") else {
            Issue.record("valid runtime should allow batch and custom commands")
            return
        }
        #expect(runner.allCalls.map(\.arguments) == [
            ["version-info", "--json"], ["status-batch", "--task-ids=one", "--json"],
            ["version-info", "--json"], ["custom-command", "--json"]
        ])
    }

    @Test
    func givenSetupMutation_whenProbed_thenPairedCtlUsesTheSameEnvironmentBeforeSetupLaunch() async {
        let runner = compatibleRunner { call in
            call.executable.hasSuffix("harflow-setup") ? setupSuccess() : ctlSuccess()
        }
        let env = ["HOME": home, "PATH": "/usr/bin:/bin", "HARFLOW_OPEN_MONITOR": "0"]
        let setup = SetupClient(
            executable: "/runtime/harflow-setup", environment: env, runner: runner,
            pairedCtlExecutable: "/runtime/harflow-ctl"
        )
        let result = await setup.perform(.install, client: "codex")
        guard case .success = result else { Issue.record("expected setup success"); return }
        #expect(runner.allCalls.map(\.executable) == ["/runtime/harflow-ctl", "/runtime/harflow-setup"])
        #expect(runner.allCalls.map(\.environment) == [env, env])
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"], ["--client=codex", "--json"]])
    }

    @Test
    func givenFirstOperationPassesButSecondProbeFails_thenSecondCommandIsNeverLaunched() async {
        let counter = ProbeCounter()
        let runner = RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                counter.value += 1
                return counter.value == 1
                    ? ProcessOutput(exitCode: 0, stdout: versionInfo(), stderr: "")
                    : ProcessOutput(exitCode: 0, stdout: versionInfo(root: "/tmp/replaced/.harflow"), stderr: "")
            }
            return ctlSuccess()
        }
        let client = client(runner)
        guard case .success = await client.list() else {
            Issue.record("first operation should pass")
            return
        }
        guard case .failure = await client.list() else {
            Issue.record("second operation should fail its fresh probe")
            return
        }
        #expect(runner.allCalls.map(\.arguments) == [
            ["version-info", "--json"], ["list", "--json"], ["version-info", "--json"]
        ])
    }

    @Test
    func givenWrongSetupStateRoot_whenMutating_thenSetupIsNotLaunched() async {
        let runner = RecordingRunner { _ in
            ProcessOutput(exitCode: 0, stdout: versionInfo(root: "/tmp/wrong/.harflow"), stderr: "")
        }
        let setup = SetupClient(
            executable: "/runtime/harflow-setup", environment: ["HOME": home], runner: runner,
            pairedCtlExecutable: "/runtime/harflow-ctl"
        )
        guard case .failure = await setup.perform(.install, client: "codex") else {
            Issue.record("wrong state root should refuse setup")
            return
        }
        #expect(runner.calls.isEmpty)
    }

    @Test
    func givenValidSetupProbe_whenSetupResponseIsForeignOrIncompatible_thenMutationFails() async {
        let answers: [Data] = [
            json("{\"product\":\"polybridge\",\"format\":\"harflow.setup\",\"v\":1,\"product_version\":\"1.0.0\",\"clients\":[]}"),
            json("{\"product\":\"harflow\",\"format\":\"harflow.ctl\",\"v\":1,\"product_version\":\"1.0.0\",\"clients\":[]}"),
            json("{\"product\":\"harflow\",\"format\":\"harflow.setup\",\"v\":1,\"product_version\":\"1.1.0\",\"clients\":[]}")
        ]
        for answer in answers {
            let runner = compatibleRunner { call in
                call.executable.hasSuffix("harflow-setup") ? ProcessOutput(exitCode: 0, stdout: answer, stderr: "") : ctlSuccess()
            }
            let setup = SetupClient(
                executable: "/runtime/harflow-setup", environment: ["HOME": home], runner: runner,
                pairedCtlExecutable: "/runtime/harflow-ctl"
            )
            let result = await setup.perform(.install, client: "codex")
            guard case .failure = result else { Issue.record("expected setup response validation failure"); continue }
            #expect(runner.calls.count == 1)
        }
    }
}

private final class ProbeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        get { lock.withLock { count } }
        set { lock.withLock { count = newValue } }
    }
}
