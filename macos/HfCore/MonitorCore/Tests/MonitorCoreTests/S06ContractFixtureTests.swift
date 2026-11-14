import Foundation
@testable import MonitorCore
import Testing

// MARK: - S06ContractFixtureTests

@Suite
struct S06ContractFixtureTests {
    private let home = "/tmp/harflow-fixture-home"
    private var context: RuntimeCompatibilityContext {
        .derived(environment: ["HOME": home])
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "ContractsV1"))
        return try Data(contentsOf: url)
    }

    @Test(arguments: [WireContract.ctl, .setup, .events])
    func givenOneUnsupportedAdvertisedContract_whenRequiringContracts_thenOnlyThatContractFails(_ changed: WireContract) throws {
        // given
        var object = try #require(JSONValue.parse(fixture("version-info-s05-additive.json"))?.objectValue)
        var contracts = try #require(object["contracts"]?.objectValue)
        var advertised = try #require(contracts[changed.rawValue]?.objectValue)
        advertised["v"] = .number(2)
        contracts[changed.rawValue] = .object(advertised)
        object["contracts"] = .object(contracts)
        let data = Data(JSONValue.object(object).rendered().utf8)

        // when / then
        for required in [WireContract.ctl, .setup, .events] {
            let result = VersionInfoDocument.decode(stdout: data, context: context, requiring: [required])
            if required == changed {
                guard case .failure(.refused(code: "incompatible_runtime", message: _)) = result else {
                    Issue.record("unsupported \(changed.rawValue) contract was accepted")
                    continue
                }
            } else {
                _ = try result.get()
            }
        }
    }

    @Test
    func givenAdditiveVersionInfo_whenDecoded_thenUnknownCapabilityAndKnownContractsSurvive() throws {
        // given
        let data = try fixture("version-info-s05-additive.json")

        // when
        let info = try VersionInfoDocument.decode(stdout: data, context: context, requiring: [.ctl, .setup, .events]).get()

        // then
        #expect(info.capabilities.contains("future-capability.v99"))
        #expect(info.capabilities.contains("task-event-page.v1"))
        #expect(info.contracts.count == 3)
        #expect(info.stateRoot == home + "/.harflow")
    }

    @Test(arguments: ["task-event-page", "task-prompt", "task-successors", "workflow-live-activity", "statistics-cost-model", "task-changes",
                           "task-continue", "task-artifacts", "task-continuation-stop", "task-cancel-cascade", "backend-models"])
    func givenMissingS05Capability_whenRequested_thenBaseDecodeSucceedsButCommandNeverDispatches(_ capability: String) async throws {
        // given
        let data = try fixture("invalid-s05-missing-\(capability).json")
        let info = try VersionInfoDocument.decode(stdout: data, context: context).get()
        #expect(!info.capabilities.contains(capability + ".v1"))
        let runner = RecordingRunner { _ in ProcessOutput(exitCode: 0, stdout: data, stderr: "") }
        let client = CtlClient(executable: "/runtime/harflow-ctl", environment: ["HOME": home], runner: runner)

        // when
        let result = await client.raw("s06-requested-command", requiringCapability: capability + ".v1")

        // then
        guard case .failure(.unsupportedCommand(_, let command, let detail)) = result else {
            Issue.record("missing capability did not refuse command")
            return
        }
        #expect(command == "s06-requested-command")
        #expect(detail.contains(capability + ".v1"))
        #expect(runner.calls.isEmpty)
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"]])
    }

    @Test(arguments: [
        "ctl-launch-run-accepted.json", "ctl-launch-resume-accepted.json",
        "ctl-launch-run-refused.json", "ctl-launch-resume-refused.json",
        "ctl-launch-run-unknown.json", "ctl-launch-resume-unknown.json", "ctl-launch-unknown-operation.json"
    ])
    func givenLaunchFixture_whenRequiringSuccess_thenOutcomeRetainsItsClassification(_ name: String) throws {
        // given
        let manifest = try #require(JSONValue.parse(fixture("manifest.json"))?.objectValue)
        let metadata = try #require(manifest["cases"]?.objectValue?[name]?.objectValue)
        let exitCode = try #require(metadata["exit_code"]?.intValue)
        let command = name.contains("resume") ? "resume" : (name.contains("unknown-operation") ? "s05-unknown-operation" : "run")

        // when
        let result = CtlDocument.decode(stdout: try fixture(name), stderr: "", exitCode: Int32(exitCode), command: command).requiringSuccess()

        // then
        if name.contains("accepted") {
            guard case .success(.result(let payload)) = result else {
                Issue.record("accepted launch did not succeed")
                return
            }
            #expect(payload["task_id"]?.stringValue == "task-fixture")
        } else if name.contains("refused") {
            guard case .failure(.refused(let code, let message)) = result else {
                Issue.record("refused launch lost refusal")
                return
            }
            #expect(code == "invalid_params")
            #expect(message == "fixture refusal")
        } else if name.contains("unknown-operation") {
            guard case .failure(.unsupportedCommand(_, let unsupported, _)) = result else {
                Issue.record("usage error did not map to unsupported command")
                return
            }
            #expect(unsupported == command)
        } else {
            guard case .failure(.unknownOutcome(let message)) = result else {
                Issue.record("uncertain launch lost unknown outcome")
                return
            }
            #expect(message.contains("a task may exist"))
        }
    }

    @Test(arguments: ["ctl-launch-continue-accepted.json", "ctl-launch-continue-refused.json", "ctl-launch-continue-unknown.json"])
    func givenContinueLaunchFixture_whenRequiringSuccess_thenOutcomeRetainsItsClassification(_ name: String) throws {
        // given
        let manifest = try #require(JSONValue.parse(fixture("manifest.json"))?.objectValue)
        let metadata = try #require(manifest["cases"]?.objectValue?[name]?.objectValue)
        let exitCode = try #require(metadata["exit_code"]?.intValue)
        #expect(metadata["required_capabilities"]?.arrayValue?.compactMap(\.stringValue) == [CtlCapability.taskContinue])

        // when
        let result = CtlDocument.decode(stdout: try fixture(name), stderr: "", exitCode: Int32(exitCode), command: "continue").requiringSuccess()

        // then
        switch name {
        case "ctl-launch-continue-accepted.json":
            guard case .success(.result(let payload)) = result else {
                Issue.record("accepted continue did not succeed")
                return
            }
            #expect(payload["task_id"]?.stringValue == "task-fixture")
        case "ctl-launch-continue-refused.json":
            guard case .failure(let error) = result, case .refused(let code, let message) = error else {
                Issue.record("plain continue refusal lost its classification")
                return
            }
            #expect(code == "invalid_params")
            #expect(message == "fixture refusal")
            #expect(error.chainStopped == nil)
        default:
            guard case .failure(.unknownOutcome(let message)) = result else {
                Issue.record("uncertain continue lost unknown outcome")
                return
            }
            #expect(message.contains("a task may exist"))
        }
    }

    @Test
    func givenChainStoppedContinueRefusal_whenDecoded_thenItIsStructuredAndReadsTypedReason() throws {
        // given
        let name = "ctl-continue-chain-stopped.json"

        // when
        let result = CtlDocument.decode(stdout: try fixture(name), stderr: "", exitCode: 1, command: "continue").requiringSuccess()

        // then
        guard case .failure(let error) = result, case .structuredRefusal(let code, _, let data) = error else {
            Issue.record("chain-stopped refusal did not decode as a structured refusal")
            return
        }
        #expect(code == "start_failed")
        #expect(data["reason"]?.stringValue == "chain_stopped")
        #expect(error.chainStopped == ChainStoppedRefusal(chainRootTaskID: "task-continuation-stop"))
    }

    @Test(arguments: [
        "ctl-task-events-incomplete.json", "ctl-task-prompt-preview-only.json",
        "ctl-task-page-successors-none-found.json", "ctl-workflow-inspect-live-no-attempt.json",
        "ctl-statistics-page-cost-reported-and-silent.json", "ctl-task-changes-available-listing.json"
    ])
    func givenS04CapabilityResult_whenDecoded_thenOpaqueMetadataIsPreserved(_ name: String) throws {
        // given
        var object = try #require(JSONValue.parse(fixture(name))?.objectValue)
        var expected = try #require(object["result"]?.objectValue)
        expected["future_metadata"] = .object(["nullable": .null, "incomplete": .bool(true)])
        object["result"] = .object(expected)
        let data = Data(JSONValue.object(object).rendered().utf8)

        // when
        let result = CtlDocument.decode(stdout: data, stderr: "", exitCode: 0, command: "task-events", eventPage: true)

        // then
        guard case .success(.result(let payload)) = result else {
            Issue.record("capability fixture failed to decode: \(name)")
            return
        }
        #expect(payload == expected)
        if name == "ctl-task-events-incomplete.json" {
            #expect(payload["log"]?.objectValue?["state"]?.stringValue == "incomplete")
            #expect(payload["log"]?.objectValue?["final_seq"] == .null)
        }
        if name == "ctl-task-prompt-preview-only.json" {
            #expect(payload["prompt"]?.objectValue?["complete"] == .bool(false))
            #expect(payload["prompt"]?.objectValue?["total_bytes"] == .null)
        }
        if name == "ctl-task-page-successors-none-found.json" {
            #expect(payload["counts_complete"] == .bool(false))
            #expect(payload["total_active_count"] == .null)
        }
        if name == "ctl-workflow-inspect-live-no-attempt.json" {
            #expect(payload["task_id"] == .null)
            #expect(payload["activity_state"]?.stringValue == "not_started")
        }
    }

    @Test
    func givenTaskEventsWithInvalidInnerVersion_whenExplicitlyDecodingEventPage_thenItIsRejected() throws {
        // given
        var object = try #require(JSONValue.parse(fixture("ctl-task-events-incomplete.json"))?.objectValue)
        var payload = try #require(object["result"]?.objectValue)
        var events = try #require(payload["events"]?.arrayValue)
        var event = try #require(events.first?.objectValue)
        event["v"] = .number(2)
        events[0] = .object(event)
        payload["events"] = .array(events)
        object["result"] = .object(payload)

        // when
        let result = CtlDocument.decode(stdout: Data(JSONValue.object(object).rendered().utf8), stderr: "", exitCode: 0,
                                        command: "task-events", eventPage: true)

        // then
        guard case .failure(.unsupportedVersion) = result else {
            Issue.record("task-events accepted unsupported inner event version")
            return
        }
    }
}
