import Foundation
@testable import MonitorCore
import Testing

/// Pins the shared incompatibility details against the output of the real producers, so a classifier built on
/// `WireEnvelope.Detail` cannot drift from the messages `WireEnvelope.validate` and `VersionInfoDocument.decode` print.
@Suite
struct WireEnvelopeDetailTests {
    private let root = "/tmp/harflow-fixture-home/.harflow"

    private func envelope(
        product: String = "harflow", format: String = "harflow.ctl", productVersion: String = HarflowVersion.current
    ) -> [String: JSONValue] {
        ["product": .string(product), "format": .string(format), "v": .number(1), "product_version": .string(productVersion)]
    }

    private func versionInfo(
        operatingSystem: String = "darwin", stateRoot: String? = nil,
        capabilities: [String] = ["ctl.v1", "setup.v1", "events.v1", "version-info.v1"],
        contracts: String = #""ctl":{"format":"harflow.ctl","v":1},"setup":{"format":"harflow.setup","v":1},"events":{"format":"harflow.event","v":1}"#
    ) -> Data {
        let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
        return Data("""
        {"product":"harflow","format":"harflow.version-info","v":1,"product_version":"\(HarflowVersion.current)","component":"engine",
        "state_root":"\(stateRoot ?? root)","contracts":{\(contracts)},"capabilities":[\(caps)],"os":"\(operatingSystem)","architecture":"arm64"}
        """.utf8)
    }

    private func decode(_ data: Data, requiring: Set<WireContract> = [.ctl]) -> ToolError? {
        let context = RuntimeCompatibilityContext(expectedStateRoot: root)
        guard case .failure(let error) = VersionInfoDocument.decode(stdout: data, context: context, requiring: requiring) else { return nil }
        return error
    }

    @Test
    func givenEachEnvelopeIncompatibility_whenValidated_thenTheDetailMatchesTheSharedConstants() {
        // given
        let foreign = WireEnvelope.validate(envelope(product: "other"), contract: .ctl)
        let format = WireEnvelope.validate(envelope(format: "harflow.setup"), contract: .ctl)
        let version = WireEnvelope.validate(envelope(productVersion: "not-a-version"), contract: .ctl)
        let line = WireEnvelope.validate(envelope(productVersion: "9.9.0"), contract: .ctl)
        // when
        let details = [foreign, format, version, line].map { $0.flatMap(WireEnvelope.Detail.of) }
        // then
        #expect(details[0] == WireEnvelope.Detail.foreignProductIdentity)
        #expect(details[1] == "unsupported harflow.ctl format")
        #expect(details[1].map(WireEnvelope.Detail.isUnsupportedFormat) == true)
        #expect(details[2] == WireEnvelope.Detail.invalidProductVersion)
        #expect(details[3]?.hasPrefix(WireEnvelope.Detail.releaseLineDiffersPrefix) == true)
        #expect(details[3] == WireEnvelope.Detail.releaseLineDiffers(from: HarflowVersion.current))
    }

    @Test
    func givenEachVersionInfoIncompatibility_whenDecoded_thenTheDetailMatchesTheSharedConstants() {
        // given / when
        let mismatch = decode(versionInfo(stateRoot: "/tmp/other/.harflow"))
        let platform = decode(versionInfo(operatingSystem: "linux"))
        let capability = decode(versionInfo(capabilities: ["setup.v1", "events.v1", "version-info.v1"]))
        let contract = decode(versionInfo(contracts: #""setup":{"format":"harflow.setup","v":1}"#))
        // then
        #expect(mismatch.flatMap(WireEnvelope.Detail.of) == WireEnvelope.Detail.invalidVersionInfo)
        #expect(platform.flatMap(WireEnvelope.Detail.of) == WireEnvelope.Detail.requiresDarwinArm64)
        #expect(capability.flatMap(WireEnvelope.Detail.of) == WireEnvelope.Detail.missingCapability("ctl.v1"))
        #expect(capability.flatMap(WireEnvelope.Detail.of) == "missing required ctl.v1 capability")
        #expect(contract.flatMap(WireEnvelope.Detail.of) == WireEnvelope.Detail.missingContract("ctl.v1"))
        #expect(contract.flatMap(WireEnvelope.Detail.of) == "missing required ctl.v1 contract/capability")
        for error in [capability, contract] {
            #expect(error.flatMap(WireEnvelope.Detail.of)?.hasPrefix(WireEnvelope.Detail.missingRequiredPrefix) == true)
        }
    }

    @Test
    func givenAnIncompatibility_whenItsMessageIsRead_thenItCarriesTheSharedPrefixAndCode() {
        // given / when
        let error = WireEnvelope.incompatibility("anything")
        // then
        #expect(error == .refused(code: "incompatible_runtime", message: "Incompatible Harflow runtime: anything"))
        #expect(WireEnvelope.incompatibleRuntimeCode == "incompatible_runtime")
    }

    @Test
    func givenErrorsThatAreNotIncompatibilities_whenDetailIsRead_thenItIsNil() {
        // given
        let errors: [ToolError] = [
            .refused(code: "state_incompatible", message: "Incompatible Harflow runtime: missing required x"),
            .refused(code: "incompatible_runtime", message: "something else"),
            .structuredRefusal(code: "incompatible_runtime", message: "Incompatible Harflow runtime: x", data: [:]),
            .timedOut(tool: "harflow-ctl", seconds: 1)
        ]
        // when / then
        for error in errors { #expect(WireEnvelope.Detail.of(error) == nil) }
    }

    @Test
    func givenUnsupportedFormatMatcher_whenGivenNearMisses_thenItIsStrict() {
        #expect(WireEnvelope.Detail.isUnsupportedFormat("unsupported harflow.event format"))
        #expect(!WireEnvelope.Detail.isUnsupportedFormat("unsupported format"))
        #expect(!WireEnvelope.Detail.isUnsupportedFormat("unsupported harflow.ctl"))
        #expect(!WireEnvelope.Detail.isUnsupportedFormat("harflow.ctl format"))
    }
}
