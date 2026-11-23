import Foundation
@testable import MonitorCore
import Testing

@Suite
struct WireContractRefusalTests {
    private let stateRoot = "/tmp/harflow-fixture-home/.harflow"

    private func envelope(_ contract: WireContract, version: Int) -> [String: JSONValue] {
        ["product": .string("harflow"), "format": .string(contract.format), "v": .number(Double(version)),
         "product_version": .string(HarflowVersion.current)]
    }

    @Test
    func givenEachContract_whenRefusedForItsVersion_thenTheMessageNamesTheUserFacingTool() {
        // given
        let expected: [(WireContract, String)] = [
            (.ctl, "harflow-ctl answered with contract version 2; this app understands version 1. "
                + "Update the app or harflow so they match."),
            (.setup, "harflow-setup answered with contract version 2; this app understands version 1. "
                + "Update the app or harflow so they match."),
            (.events, "harflow-ctl answered with contract version 2; this app understands version 1. "
                + "Update the app or harflow so they match."),
            (.versionInfo, "harflow-ctl version-info answered with contract version 2; this app understands version 1. "
                + "Update the app or harflow so they match.")
        ]
        #expect(expected.count == WireContract.allCases.count)
        for (contract, message) in expected {
            // when
            let error = WireEnvelope.validate(envelope(contract, version: 2), contract: contract)
            // then
            #expect(error?.message == message)
            #expect(!(error?.message.contains("`") ?? true))
        }
    }

    @Test
    func givenEachContract_whenEnvelopeIsTheUnderstoodVersion_thenItIsAccepted() {
        for contract in WireContract.allCases {
            // given / when / then
            #expect(WireEnvelope.validate(envelope(contract, version: 1), contract: contract) == nil)
        }
    }

    @Test
    func givenEachContract_whenUnderstoodVersionsAreRead_thenTheyComeFromTheContractsOwnConstant() {
        #expect(WireContract.ctl.understoodVersions == ctlContractVersions)
        #expect(WireContract.setup.understoodVersions == [setupContractVersion])
        #expect(WireContract.events.understoodVersions == [eventLogVersion])
        #expect(WireContract.versionInfo.understoodVersions == [versionInfoContractVersion])
    }

    @Test
    func givenCtlAndEventLogContracts_whenUnderstoodVersionsAreCompared_thenTheyAreEqual() {
        // The refusal message resolves its set by tool name, and both contracts report as "harflow-ctl",
        // so the message renders the ctl set for event refusals. The sets must stay equal while they share a name.
        #expect(WireContract.events.toolName == WireContract.ctl.toolName)
        #expect(WireContract.events.understoodVersions == WireContract.ctl.understoodVersions)
    }

    @Test
    func givenAnEnvelopeWithoutAVersion_whenValidated_thenTheRefusalSaysNone() {
        // given
        var document = envelope(.setup, version: 1)
        document["v"] = nil
        // when
        let error = WireEnvelope.validate(document, contract: .setup)
        // then
        #expect(error?.message.contains("contract version none") == true)
        #expect(error?.message.hasPrefix("harflow-setup answered") == true)
    }

    @Test
    func givenAnUnknownTool_whenRefused_thenTheMessageFallsBackToTheEventLogVersion() {
        // given / when
        let message = ToolError.unsupportedVersion(tool: "other-tool", version: "4").message
        // then
        #expect(message == "other-tool answered with contract version 4; this app understands version 1. "
            + "Update the app or harflow so they match.")
    }

    @Test
    func givenAnAdvertisedContractVersionOutsideTheUnderstoodSet_whenVersionInfoIsDecoded_thenItIsIncompatible() throws {
        // given
        let url = try #require(Bundle.module.url(forResource: "version-info.json", withExtension: nil, subdirectory: "ContractsV1"))
        var object = try #require(JSONValue.parse(try Data(contentsOf: url))?.objectValue)
        var contracts = try #require(object["contracts"]?.objectValue)
        contracts["setup"] = .object(["format": .string("harflow.setup"), "v": .number(2)])
        object["contracts"] = .object(contracts)
        let data = Data(JSONValue.object(object).rendered().utf8)
        // when
        let result = VersionInfoDocument.decode(
            stdout: data, context: RuntimeCompatibilityContext(expectedStateRoot: stateRoot), requiring: [.setup]
        )
        // then
        guard case .failure(let error) = result else { Issue.record("expected an incompatible runtime"); return }
        #expect(error.message.contains("missing required setup.v1 contract/capability"))
    }
}
