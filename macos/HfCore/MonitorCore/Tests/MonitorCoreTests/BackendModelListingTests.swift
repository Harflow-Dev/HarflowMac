import Foundation
@testable import MonitorCore
import Testing

// MARK: - BackendModelListingTests

@Suite
struct BackendModelListingTests {
    struct Expectation: Sendable, CustomTestStringConvertible {
        let fixture: String
        let backend: String
        let state: BackendModelListing.State
        let reason: BackendModelListing.Reason?
        let source: BackendModelListing.Source?
        let rows: Int
        let truncated: Bool
        var testDescription: String { fixture }
    }

    private static let listings: [Expectation] = [
        .init(fixture: "ctl-backend-models-available-antigravity.json", backend: "antigravity", state: .available,
              reason: nil, source: .cliOutput, rows: 6, truncated: false),
        .init(fixture: "ctl-backend-models-available-claude.json", backend: "claude", state: .available,
              reason: nil, source: .documentedAliases, rows: 3, truncated: false),
        .init(fixture: "ctl-backend-models-available-codex.json", backend: "codex", state: .available,
              reason: nil, source: .harnessCache, rows: 4, truncated: false),
        .init(fixture: "ctl-backend-models-available-cursor.json", backend: "cursor", state: .available,
              reason: nil, source: .cliOutput, rows: 7, truncated: false),
        .init(fixture: "ctl-backend-models-available-opencode.json", backend: "opencode", state: .available,
              reason: nil, source: .cliOutput, rows: 6, truncated: false),
        .init(fixture: "ctl-backend-models-available-vibe.json", backend: "vibe", state: .available,
              reason: nil, source: .configAliases, rows: 3, truncated: false),
        .init(fixture: "ctl-backend-models-not-installed.json", backend: "claude", state: .notInstalled,
              reason: nil, source: .documentedAliases, rows: 0, truncated: false),
        .init(fixture: "ctl-backend-models-truncated.json", backend: "opencode", state: .available,
              reason: nil, source: .cliOutput, rows: 400, truncated: true),
        .init(fixture: "ctl-backend-models-unavailable-auth-required.json", backend: "cursor", state: .unavailable,
              reason: .authRequired, source: .cliOutput, rows: 0, truncated: false),
        .init(fixture: "ctl-backend-models-unavailable-exit-nonzero.json", backend: "antigravity", state: .unavailable,
              reason: .exitNonzero, source: .cliOutput, rows: 0, truncated: false),
        .init(fixture: "ctl-backend-models-unavailable-source-missing.json", backend: "codex", state: .unavailable,
              reason: .sourceMissing, source: .harnessCache, rows: 0, truncated: false),
        .init(fixture: "ctl-backend-models-unavailable-timeout.json", backend: "opencode", state: .unavailable,
              reason: .timeout, source: .cliOutput, rows: 0, truncated: false),
        .init(fixture: "ctl-backend-models-unavailable-unparseable.json", backend: "antigravity", state: .unavailable,
              reason: .unparseable, source: .cliOutput, rows: 0, truncated: false)
    ]

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ContractsV1"))
        return try Data(contentsOf: url)
    }

    private func exitCode(of name: String) throws -> Int32 {
        let manifest = try #require(JSONValue.parse(fixture("manifest.json"))?.objectValue)
        let metadata = try #require(manifest["cases"]?.objectValue?[name]?.objectValue)
        return Int32(try #require(metadata["exit_code"]?.intValue))
    }

    private func decode(fixture name: String) throws -> BackendModelsOutcome {
        BackendModelsOutcome.decode(
            output: ProcessOutput(exitCode: try exitCode(of: name), stdout: try fixture(name), stderr: ""),
            productVersion: HarflowVersion.current
        )
    }

    private func decode(_ text: String, exitCode: Int32 = 0) -> BackendModelsOutcome {
        BackendModelsOutcome.decode(output: ProcessOutput(exitCode: exitCode, stdout: ctlJSON(text), stderr: ""),
                                    productVersion: HarflowVersion.current)
    }

    private func listing(fixture name: String) throws -> BackendModelListing {
        guard case .listing(let listing) = try decode(fixture: name) else {
            Issue.record("\(name) did not decode to a listing")
            throw DecodeFailure()
        }
        return listing
    }

    private struct DecodeFailure: Error {}

    // MARK: Vendored specimens

    @Test(arguments: listings)
    func givenVendoredListingSpecimen_whenDecoded_thenStateReasonSourceAndRowsMatch(_ expected: Expectation) throws {
        // when
        let listing = try listing(fixture: expected.fixture)

        // then
        #expect(listing.backend == expected.backend)
        #expect(listing.state == expected.state)
        #expect(listing.reason == expected.reason)
        #expect(listing.source == expected.source)
        #expect(listing.models.count == expected.rows)
        #expect(listing.truncated == expected.truncated)
        #expect(listing.scope == "user")
        #expect(listing.advisory)
        #expect(listing.droppedCount == 0)
        #expect(listing.harnessVersion == nil)
        #expect(!listing.observedAt.isEmpty)
    }

    @Test
    func givenCodexSpecimen_whenDecoded_thenEmptyEffortListIsDistinctFromAbsent() throws {
        // when
        let listing = try listing(fixture: "ctl-backend-models-available-codex.json")

        // then
        #expect(listing.sourceObservedAt == "2026-11-13T05:47:45Z")
        #expect(listing.models.filter { $0.effortLevels == [] }.count == 1)
        #expect(listing.models.allSatisfy { $0.effortLevels != nil })
        #expect(listing.models.allSatisfy { $0.isDefault == nil })
    }

    @Test
    func givenOpencodeSpecimen_whenDecoded_thenRowOrderLevelsAndAbsentLevelsArePreserved() throws {
        // when
        let listing = try listing(fixture: "ctl-backend-models-available-opencode.json")

        // then
        #expect(listing.models.first?.id == "opencode/beam-free")
        #expect(listing.models.first?.label == "Beam Free")
        #expect(listing.models.first?.effortLevels?.count == 4)
        #expect(listing.models.map(\.id).contains("opencode/big-pickle"))
        #expect(listing.models.first { $0.id == "opencode/big-pickle" }?.effortLevels == nil)
        #expect(listing.models.filter { $0.effortLevels == nil }.count == 1)
    }

    @Test(arguments: ["ctl-backend-models-available-cursor.json", "ctl-backend-models-available-vibe.json"])
    func givenSpecimenThatMarksDefaults_whenDecoded_thenBothTrueAndFalseAreKept(_ name: String) throws {
        // when
        let listing = try listing(fixture: name)

        // then
        #expect(listing.models.contains { $0.isDefault == true })
        #expect(listing.models.contains { $0.isDefault == false })
        #expect(listing.models.allSatisfy { $0.effortLevels == nil })
    }

    @Test
    func givenNotInstalledSpecimen_whenDecoded_thenSourceMayBePresentWithoutRows() throws {
        // when
        let listing = try listing(fixture: "ctl-backend-models-not-installed.json")

        // then
        #expect(listing.state == .notInstalled)
        #expect(listing.source == .documentedAliases)
        #expect(listing.models.isEmpty)
    }

    @Test
    func givenAgentRefusal_whenDecoded_thenItIsRefusedWithoutDetail() throws {
        // when
        let outcome = try decode(fixture: "ctl-backend-models-agent-refused.json")

        // then
        #expect(outcome == .refused(code: "agent_caller", detail: nil))
    }

    @Test
    func givenUndecidableRefusal_whenDecoded_thenItCarriesTheEngineDetail() throws {
        // when
        let outcome = try decode(fixture: "ctl-backend-models-undecidable-unmarked-root.json")

        // then
        #expect(outcome == .refused(code: "caller_undecidable", detail: "root_present_unmarked"))
    }

    @Test
    func givenUnknownBackendUsageDocument_whenDecoded_thenItFailsAsUnsupportedCommand() throws {
        // when
        let outcome = try decode(fixture: "ctl-backend-models-usage-unknown-backend.json")

        // then
        guard case .failed(.unsupportedCommand(_, let command, let detail)) = outcome else {
            Issue.record("usage document was not a failure: \(outcome)")
            return
        }
        #expect(command == "backend-models")
        #expect(detail.contains("invalid choice"))
    }

    // MARK: Additive and synthetic values

    private static let baseResult = """
    {"backend":"opencode","state":"available","reason":null,"source":"cli_output","scope":"user","advisory":true,\
    "harness_version":null,"source_observed_at":null,"observed_at":"2026-11-14T00:00:00Z","truncated":false,\
    "dropped_count":0,"models":[{"id":"a/b","label":"A B","default":null,"effort_levels":null}]}
    """

    private func result(replacing key: String, with value: String?) throws -> String {
        var object = try #require(JSONValue.parse(Data(Self.baseResult.utf8))?.objectValue)
        if let value { object[key] = try #require(JSONValue.parse(Data(value.utf8))) } else { object[key] = nil }
        return "{\"result\":" + JSONValue.object(object).rendered() + "}"
    }

    @Test
    func givenUnsupportedState_whenDecoded_thenItIsAKnownState() throws {
        // given
        let text = try result(replacing: "state", with: "\"unsupported\"")

        // when
        let outcome = decode(text)

        // then
        guard case .listing(let listing) = outcome else { Issue.record("not a listing"); return }
        #expect(listing.state == .unsupported)
    }

    @Test
    func givenUnknownStateReasonAndSource_whenDecoded_thenTheyAreKeptAsUnrecognized() throws {
        // given
        var text = try result(replacing: "state", with: "\"throttled\"")
        text = text.replacingOccurrences(of: "\"reason\":null", with: "\"reason\":\"rate_limited\"")
            .replacingOccurrences(of: "\"source\":\"cli_output\"", with: "\"source\":\"remote_catalog\"")

        // when
        let outcome = decode(text)

        // then
        guard case .listing(let listing) = outcome else { Issue.record("not a listing: \(outcome)"); return }
        #expect(listing.state == .unrecognized("throttled"))
        #expect(listing.reason == .unrecognized("rate_limited"))
        #expect(listing.source == .unrecognized("remote_catalog"))
    }

    @Test
    func givenUnknownExtraFields_whenDecoded_thenTheyAreIgnoredInResultAndRows() throws {
        // given
        var object = try #require(JSONValue.parse(Data(Self.baseResult.utf8))?.objectValue)
        object["future_field"] = .string("x")
        var row = try #require(object["models"]?.arrayValue?.first?.objectValue)
        row["pricing"] = .object(["tier": .string("free")])
        object["models"] = .array([.object(row)])
        let text = "{\"result\":" + JSONValue.object(object).rendered() + "}"

        // when
        let outcome = decode(text)

        // then
        guard case .listing(let listing) = outcome else { Issue.record("not a listing"); return }
        #expect(listing.models == [BackendModel(id: "a/b", label: "A B")])
    }

    @Test
    func givenAbsentOptionalFields_whenDecoded_thenTheyReadAsNil() throws {
        // given
        var object = try #require(JSONValue.parse(Data(Self.baseResult.utf8))?.objectValue)
        for key in ["reason", "source", "harness_version", "source_observed_at"] { object[key] = nil }
        var row = try #require(object["models"]?.arrayValue?.first?.objectValue)
        row["default"] = nil
        row["effort_levels"] = nil
        object["models"] = .array([.object(row)])

        // when
        let outcome = decode("{\"result\":" + JSONValue.object(object).rendered() + "}")

        // then
        guard case .listing(let listing) = outcome else { Issue.record("not a listing"); return }
        #expect(listing.reason == nil && listing.source == nil && listing.harnessVersion == nil)
        #expect(listing.models.first?.isDefault == nil && listing.models.first?.effortLevels == nil)
    }

    // MARK: Malformed documents

    private static let malformed: [(String, String?)] = [
        ("backend", nil), ("backend", "\"\""), ("backend", "3"), ("state", nil), ("state", "true"), ("scope", nil),
        ("advisory", "\"yes\""), ("advisory", nil), ("observed_at", nil), ("truncated", "1"), ("truncated", nil),
        ("dropped_count", "-1"), ("dropped_count", "1.5"), ("dropped_count", nil), ("models", nil), ("models", "{}"),
        ("reason", "7"), ("source", "[]"), ("harness_version", "1"), ("source_observed_at", "false"),
        ("models", "[3]"), ("models", "[{\"label\":\"x\"}]"), ("models", "[{\"id\":\"\",\"label\":\"x\"}]"),
        ("models", "[{\"id\":\"a\"}]"), ("models", "[{\"id\":\"a\",\"label\":\"x\",\"default\":\"true\"}]"),
        ("models", "[{\"id\":\"a\",\"label\":\"x\",\"effort_levels\":\"low\"}]"),
        ("models", "[{\"id\":\"a\",\"label\":\"x\",\"effort_levels\":[\"low\",3]}]")
    ]

    @Test(arguments: malformed.indices)
    func givenMalformedField_whenDecoded_thenTheWholeDocumentIsUnreadable(_ index: Int) throws {
        // given
        let (key, value) = Self.malformed[index]

        // when
        let outcome = decode(try result(replacing: key, with: value))

        // then
        guard case .failed(.unreadable) = outcome else {
            Issue.record("\(key)=\(value ?? "absent") was accepted: \(outcome)")
            return
        }
    }

    @Test
    func givenResultMissing_whenDecoded_thenItIsUnreadable() {
        // when
        let outcome = decode("{\"something\":{}}")

        // then
        guard case .failed(.unreadable) = outcome else { Issue.record("accepted: \(outcome)"); return }
    }

    @Test
    func givenListingBodyWithFailingExitCode_whenDecoded_thenItIsUnreadable() {
        // when
        let outcome = decode(Self.baseResult.replacingOccurrences(of: "{\"backend\"", with: "{\"result\":{\"backend\"") + "}", exitCode: 1)

        // then
        guard case .failed(.unreadable) = outcome else { Issue.record("accepted: \(outcome)"); return }
    }

    /// A valid listing envelope padded with a label so its serialised size is exactly `size` bytes.
    private func envelope(ofSize size: Int) throws -> Data {
        func make(_ pad: Int) throws -> Data {
            var object = try #require(JSONValue.parse(Data(Self.baseResult.utf8))?.objectValue)
            var row = try #require(object["models"]?.arrayValue?.first?.objectValue)
            row["label"] = .string(String(repeating: "x", count: pad))
            object["models"] = .array([.object(row)])
            return ctlJSON("{\"result\":" + JSONValue.object(object).rendered() + "}")
        }
        let base = try make(0).count
        let data = try make(size - base)
        try #require(data.count == size)
        return data
    }

    @Test
    func givenEnvelopeAtTheCeilingWithTrailingNewline_whenDecoded_thenItIsAccepted() throws {
        // given
        let output = ProcessOutput(exitCode: 0, stdout: try envelope(ofSize: BackendModelsOutcome.maximumDocumentBytes) + Data("\n".utf8), stderr: "")

        // when
        let outcome = BackendModelsOutcome.decode(output: output, productVersion: HarflowVersion.current)

        // then
        guard case .listing = outcome else { Issue.record("not a listing: \(outcome)"); return }
    }

    @Test
    func givenEnvelopeOneByteOverTheCeilingWithTrailingNewline_whenDecoded_thenItIsRefused() throws {
        // given
        let output = ProcessOutput(exitCode: 0, stdout: try envelope(ofSize: BackendModelsOutcome.maximumDocumentBytes + 1) + Data("\n".utf8), stderr: "")

        // when
        let outcome = BackendModelsOutcome.decode(output: output, productVersion: HarflowVersion.current)

        // then
        guard case .failed(.unreadable(_, _, let stderr)) = outcome else { Issue.record("accepted: \(outcome)"); return }
        #expect(stderr.contains("byte limit"))
    }

    @Test
    func givenEnvelopeOneByteOverTheCeilingWithoutNewline_whenDecoded_thenItIsRefused() throws {
        // given
        let output = ProcessOutput(exitCode: 0, stdout: try envelope(ofSize: BackendModelsOutcome.maximumDocumentBytes + 1), stderr: "")

        // when
        let outcome = BackendModelsOutcome.decode(output: output, productVersion: HarflowVersion.current)

        // then
        guard case .failed(.unreadable) = outcome else { Issue.record("accepted: \(outcome)"); return }
    }

    @Test
    func givenNonJSONOutput_whenDecoded_thenItIsUnreadable() {
        // when
        let outcome = BackendModelsOutcome.decode(output: ProcessOutput(exitCode: 1, stdout: Data("oops".utf8), stderr: "boom"),
                                                  productVersion: HarflowVersion.current)

        // then
        guard case .failed(.unreadable(_, _, let stderr)) = outcome else { Issue.record("accepted: \(outcome)"); return }
        #expect(stderr == "boom")
    }

    @Test
    func givenErrorDocumentWithoutData_whenDecoded_thenItIsAFailureNotARefusal() {
        // when
        let outcome = decode("{\"error\":{\"code\":\"internal\",\"message\":\"x\"}}", exitCode: 1)

        // then
        #expect(outcome == .failed(.refused(code: "internal", message: "x")))
    }

    @Test
    func givenRefusalWithoutKnownDetail_whenDecoded_thenDetailIsNil() {
        // when
        let outcome = decode(
            "{\"error\":{\"code\":\"caller_undecidable\",\"message\":\"m\",\"data\":{\"detail\":7,\"coverage\":\"unknown\"}}}", exitCode: 1
        )

        // then
        #expect(outcome == .refused(code: "caller_undecidable", detail: nil))
    }
}

// MARK: - BackendModelsClientTests

@Suite
struct BackendModelsClientTests {
    private func probe(_ environment: [String: String], capability: Bool) -> ProcessOutput {
        let capabilities = ["ctl.v1"] + (capability ? [CtlCapability.backendModels] : [])
        let raw: [String: JSONValue] = [
            "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
            "product_version": .string(HarflowVersion.current), "component": .string("engine"),
            "state_root": .string(RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot),
            "contracts": .object(["ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)])]),
            "capabilities": .array(capabilities.map(JSONValue.string)), "os": .string("darwin"), "architecture": .string("arm64")
        ]
        return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
    }

    private func runner(capability: Bool = true, answer: @escaping @Sendable () -> ProcessOutput) -> RecordingRunner {
        RecordingRunner { call in
            call.arguments.first == "version-info" ? probe(call.environment, capability: capability) : answer()
        }
    }

    private func fixtureOutput(_ name: String, exitCode: Int32 = 0) throws -> ProcessOutput {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ContractsV1"))
        return ProcessOutput(exitCode: exitCode, stdout: try Data(contentsOf: url), stderr: "")
    }

    @Test
    func givenCapability_whenRequested_thenOneHandshakeThenOneBackendOptionCommandRuns() async throws {
        // given
        let output = try fixtureOutput("ctl-backend-models-available-opencode.json")
        let runner = runner { output }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)

        // when
        let outcome = await client.backendModels(backend: "opencode")

        // then
        guard case .listing(let listing) = outcome else { Issue.record("not a listing: \(outcome)"); return }
        #expect(listing.backend == "opencode")
        #expect(runner.allCalls.map(\.arguments.first) == ["version-info", "backend-models"])
        #expect(runner.calls.last?.arguments == ["backend-models", "--backend=opencode", "--json"])
    }

    @Test
    func givenSecondRequest_whenRequested_thenItRunsAFreshHandshake() async throws {
        // given
        let output = try fixtureOutput("ctl-backend-models-available-opencode.json")
        let runner = runner { output }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)

        // when
        _ = await client.backendModels(backend: "opencode")
        _ = await client.backendModels(backend: "codex")

        // then
        #expect(runner.allCalls.map(\.arguments.first) == ["version-info", "backend-models", "version-info", "backend-models"])
        #expect(runner.calls.last?.arguments == ["backend-models", "--backend=codex", "--json"])
    }

    @Test
    func givenMissingCapability_whenRequested_thenOnlyTheHandshakeRuns() async {
        // given
        let runner = runner(capability: false) { ProcessOutput(exitCode: 0, stdout: Data(), stderr: "") }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)

        // when
        let outcome = await client.backendModels(backend: "opencode")

        // then
        #expect(outcome == .capabilityMissing)
        #expect(runner.allCalls.map(\.arguments.first) == ["version-info"])
    }

    @Test
    func givenAgentRefusal_whenRequested_thenOutcomeIsRefused() async throws {
        // given
        let output = try fixtureOutput("ctl-backend-models-agent-refused.json", exitCode: 1)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner { output })

        // when
        let outcome = await client.backendModels(backend: "claude")

        // then
        #expect(outcome == .refused(code: "agent_caller", detail: nil))
    }

    @Test
    func givenUsageErrorFromUnknownBackend_whenRequested_thenOutcomeIsFailedNotMissingCapability() async throws {
        // given
        let output = try fixtureOutput("ctl-backend-models-usage-unknown-backend.json", exitCode: 2)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner { output })

        // when
        let outcome = await client.backendModels(backend: "unknown-backend")

        // then
        guard case .failed(.unsupportedCommand) = outcome else { Issue.record("wrong outcome: \(outcome)"); return }
    }

    @Test
    func givenCommandTimeout_whenRequested_thenOutcomeIsFailedTimedOut() async {
        // given
        let runner = runner { ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true) }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)

        // when
        let outcome = await client.backendModels(backend: "opencode")

        // then
        guard case .failed(.timedOut) = outcome else { Issue.record("wrong outcome: \(outcome)"); return }
    }

    @Test(arguments: ["", "Opencode", "open code", "--json", "a=b", "9x", String(repeating: "a", count: 65)])
    func givenInvalidBackendName_whenRequested_thenNoProcessRuns(_ name: String) async {
        // given
        let runner = runner { ProcessOutput(exitCode: 0, stdout: Data(), stderr: "") }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)

        // when
        let outcome = await client.backendModels(backend: name)

        // then
        guard case .failed(.unreadable) = outcome else { Issue.record("accepted: \(outcome)"); return }
        #expect(runner.allCalls.isEmpty)
    }

    @Test
    func givenSupersededOperation_whenRequested_thenNoCommandRuns() async throws {
        // given
        let output = try fixtureOutput("ctl-backend-models-available-opencode.json")
        let runner = runner { output }
        var client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        client.operationIsCurrent = { false }

        // when
        let outcome = await client.backendModels(backend: "opencode")

        // then
        guard case .failed = outcome else { Issue.record("wrong outcome: \(outcome)"); return }
        #expect(runner.allCalls.isEmpty)
    }
}
