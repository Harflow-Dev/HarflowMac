import CryptoKit
import Foundation
@testable import MonitorCore
import Testing

@Suite
struct WireContractFixtureTests {
    private let root = "ContractsV1"
    private let stateRoot = "/tmp/harflow-fixture-home/.harflow"

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: root))
        return try Data(contentsOf: url)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test
    func givenContractManifest_whenEveryResourceIsHashed_thenManifestDigestAndFileHashesMatch() throws {
        let manifestData = try fixture("manifest.json")
        let manifest = try #require(JSONValue.parse(manifestData)?.objectValue)
        let files = try #require(manifest["files"]?.objectValue)

        for (name, expected) in files {
            let actual = digest(try fixture(name))
            #expect(actual == expected.stringValue)
        }

        let checksum = try String(data: fixture("manifest.sha256"), encoding: .utf8)
        #expect(checksum?.split(separator: " ").first.map(String.init) == digest(manifestData))
    }

    @Test
    func givenVersionInfoFixtures_whenDecoded_thenValidCompatibilityCasesPassAndInvalidCasesFail() throws {
        let valid: [(String, String)] = [
            ("version-info.json", HarflowVersion.current),
            ("version-info-build-metadata.json", HarflowVersion.current),
            ("version-info-patch-backward.json", "1.2.7"),
            ("version-info-patch-forward.json", "1.2.0")
        ]
        for (name, productVersion) in valid {
            let result = VersionInfoDocument.decode(
                stdout: try fixture(name),
                context: RuntimeCompatibilityContext(expectedStateRoot: stateRoot, productVersion: productVersion),
                requiring: Set(WireContract.allCases)
            )
            guard case .success = result else {
                Issue.record("expected valid version-info fixture: \(name)")
                continue
            }
        }

        let invalid = [
            "invalid-boolean-version.json", "invalid-foreign-format.json", "invalid-foreign-product.json",
            "invalid-major-mismatch.json", "invalid-malformed-product-version.json", "invalid-minor-mismatch.json",
            "invalid-missing-capabilities.json", "invalid-missing-product.json", "invalid-overflow-version.json",
            "invalid-prerelease.json", "invalid-unsupported-version.json"
        ]
        for name in invalid {
            let result = VersionInfoDocument.decode(
                stdout: try fixture(name),
                context: RuntimeCompatibilityContext(expectedStateRoot: stateRoot),
                requiring: Set(WireContract.allCases)
            )
            guard case .failure(let error) = result else {
                Issue.record("expected invalid version-info fixture: \(name)")
                continue
            }
            let expectedReason = if name.contains("boolean") || name.contains("unsupported") {
                "contract version"
            } else if name.contains("major") || name.contains("minor") {
                "major/minor release line"
            } else if name.contains("malformed") || name.contains("overflow") || name.contains("prerelease") {
                "invalid product_version"
            } else if name == "invalid-foreign-product.json" || name == "invalid-missing-product.json" {
                "foreign product identity"
            } else if name == "invalid-foreign-format.json" {
                "unsupported harflow.version-info format"
            } else if name.contains("capabilities") {
                "missing required"
            } else {
                "Incompatible Harflow runtime"
            }
            #expect(error.message.contains(expectedReason), "\(name) should explain \(expectedReason): \(error.message)")
        }
    }

    @Test
    func givenCtlAndSetupFixtures_whenDecodedWithTheirExplicitDecoders_thenPayloadsAndErrorsRemainDistinct() throws {
        let ctl = try CtlDocument.decode(stdout: fixture("ctl-success.json"), stderr: "", exitCode: 0, command: "status")
        guard case .success(.task(let task)) = ctl else {
            Issue.record("expected ctl task fixture")
            return
        }
        #expect(task.id == "task-fixture")

        let batch = CtlDocument.decodeBatchResult(
            stdout: try fixture("ctl-batch.json"), stderr: "", exitCode: 0, command: "status-batch"
        )
        guard case .success(let batch) = batch else {
            Issue.record("expected ctl batch fixture")
            return
        }
        #expect(batch.tasks.map(\.id) == ["task-fixture"])
        #expect(batch.errors["missing"]?.code == "not_found")

        let error = CtlDocument.decode(stdout: try fixture("ctl-error.json"), stderr: "", exitCode: 1, command: "status")
        #expect(error == .success(.error(code: "not_found", message: "Task not found")))

        let setup = SetupDocument.decode(stdout: try fixture("setup-success.json"), stderr: "", exitCode: 0)
        guard case .success(let setup) = setup else {
            Issue.record("expected setup fixture")
            return
        }
        #expect(setup.rows.map(\.key) == ["codex"])

        let setupError = SetupDocument.decode(stdout: try fixture("setup-error.json"), stderr: "", exitCode: 1)
        guard case .failure = setupError else {
            Issue.record("expected setup error fixture to fail")
            return
        }
    }

    @Test
    func givenEventPageFixtures_whenUsingEventPageDecoder_thenOuterVersionAndInnerEventProvenanceAreCheckedSeparately() throws {
        let current = CtlDocument.decodeEventPage(stdout: try fixture("ctl-event-page.json"))
        guard case .success(.result(let payload)) = current else {
            Issue.record("expected current event page")
            return
        }
        #expect(payload["has_more"]?.boolValue == false)

        let historical = CtlDocument.decodeEventPage(
            stdout: try fixture("ctl-event-page-historical-inner.json"), productVersion: "1.1.0"
        )
        guard case .success(.result(let historicalPayload)) = historical else {
            Issue.record("expected historical event page")
            return
        }
        #expect(historicalPayload["events"]?.arrayValue?.count == 1)
    }

    @Test
    func givenEventFixtures_whenDecodedLineByLine_thenHistoricalWriterVersionIsAcceptedAsProvenance() throws {
        for name in ["event-known.jsonl", "event-unknown.jsonl", "event-historical-writer.jsonl"] {
            let lines = try #require(String(data: fixture(name), encoding: .utf8)).split(separator: "\n")
            for line in lines {
                #expect(TaskEvent(line: String(line)) != nil)
            }
        }
    }
}
