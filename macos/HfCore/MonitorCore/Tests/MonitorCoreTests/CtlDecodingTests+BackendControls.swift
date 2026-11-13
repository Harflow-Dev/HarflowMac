import Foundation
@testable import MonitorCore
import Testing

extension CtlDecodingTests {
    private func recordedBackends(_ name: String) throws -> [BackendAvailability] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "RecordedCtl"))
        let text = try String(contentsOf: url, encoding: .utf8)
        guard case .success(.backends(let backends)) = decode(text, command: "backends") else {
            Issue.record("expected backends from \(name)")
            return []
        }
        return backends
    }

    private func controls(_ backends: [BackendAvailability], _ name: String) throws -> BackendControlFacts {
        try #require(backends.first { $0.backend == name }).controls
    }

    private func entry(capabilities: JSONValue?, qualification: JSONValue?) -> BackendControlFacts {
        var object: [String: JSONValue] = ["backend": .string("x"), "binary": .string("x"), "installed": .bool(true)]
        if let capabilities { object["capabilities"] = capabilities }
        if let qualification { object["qualification"] = qualification }
        return BackendAvailability(.object(object))?.controls ?? .unknown
    }

    private func gate(_ row: JSONValue?) -> BackendControlFacts.ModelSelectionGate {
        var features: [String: JSONValue] = ["other": .object(["ok": .bool(true), "source": .string("seeded")])]
        if let row { features["model_selection"] = row }
        return entry(capabilities: nil, qualification: .object(["features": .object(features)])).modelSelection
    }

    @Test
    func givenRecordedEngineDocument_whenDecoded_thenAllSixBackendsCarryTheReportedFacts() throws {
        // given / when
        let backends = try recordedBackends("ctl-backends-0.0.13-recorded")
        // then
        #expect(backends.map(\.backend) == ["claude", "codex", "opencode", "vibe", "antigravity", "cursor"])
        let full = ["low", "medium", "high", "xhigh"]
        let claude = try controls(backends, "claude")
        #expect(claude.supportsModelSelection == true)
        #expect(claude.supportsTurnCap == true)
        #expect(claude.effort == .init(acceptsParameter: true, levels: full))
        #expect(claude.modelSelection == .notDeclared)
        let codex = try controls(backends, "codex")
        #expect(codex.supportsTurnCap == false)
        #expect(codex.effort?.levels == full)
        #expect(codex.modelSelection == .notDeclared)
        #expect(try controls(backends, "opencode").effort?.levels == full)
        #expect(try controls(backends, "antigravity").effort == .init(acceptsParameter: true, levels: ["low", "medium", "high"]))
        let cursor = try controls(backends, "cursor")
        #expect(cursor.effort == .init(acceptsParameter: false, levels: []))
        #expect(cursor.supportsModelSelection == true)
        #expect(cursor.supportsTurnCap == false)
        let vibe = try controls(backends, "vibe")
        #expect(vibe.supportsModelSelection == true)
        #expect(vibe.supportsTurnCap == true)
        #expect(vibe.effort == .init(acceptsParameter: false, levels: []))
        #expect(vibe.modelSelection == .notReady)
    }

    @Test
    func givenSyntheticSeededVibeRow_whenDecoded_thenOnlyVibeModelSelectionIsReady() throws {
        // given / when
        let backends = try recordedBackends("ctl-backends-vibe-model-selection-seeded-synthetic")
        // then
        #expect(try controls(backends, "vibe").modelSelection == .ready)
        #expect(try controls(backends, "claude").modelSelection == .notDeclared)
    }

    @Test
    func givenNoCapabilitiesOrQualification_whenDecoded_thenEveryFactIsUnknownAndEntryStillDecodes() {
        // given / when
        let facts = entry(capabilities: nil, qualification: nil)
        // then
        #expect(facts == .unknown)
        #expect(facts.supportsModelSelection == nil)
        #expect(facts.supportsTurnCap == nil)
        #expect(facts.effort == nil)
        #expect(facts.modelSelection == .unknown)
    }

    @Test
    func givenWrongTypedFlags_whenDecoded_thenTheyReadAsNil() {
        // given / when
        let facts = entry(
            capabilities: .object(["supports_model_selection": .string("yes"), "supports_turn_cap": .number(1)]),
            qualification: nil
        )
        // then
        #expect(facts.supportsModelSelection == nil)
        #expect(facts.supportsTurnCap == nil)
    }

    @Test
    func givenMalformedEffortBlocks_whenDecoded_thenEffortIsNil() {
        // given
        func effort(_ block: JSONValue?) -> BackendControlFacts.Effort? {
            entry(capabilities: .object(block.map { ["reasoning_effort": $0] } ?? [:]), qualification: nil).effort
        }
        // when / then
        #expect(effort(nil) == nil)
        #expect(effort(.object(["levels": .array([.string("low")])])) == nil)
        #expect(effort(.object(["accepts_parameter": .string("true"), "levels": .array([])])) == nil)
        #expect(effort(.object(["accepts_parameter": .bool(true)])) == nil)
        #expect(effort(.object(["accepts_parameter": .bool(true), "levels": .array([.string("low"), .number(2)])])) == nil)
        #expect(effort(.object(["accepts_parameter": .bool(true), "levels": .array([.string("")])])) == nil)
        #expect(effort(.object(["accepts_parameter": .bool(true), "levels": .array([.string("low"), .string("low")])])) == nil)
    }

    @Test
    func givenUnknownLevelNames_whenDecoded_thenTheyAreKeptInEngineOrder() {
        // given / when
        let facts = entry(
            capabilities: .object(["reasoning_effort": .object([
                "accepts_parameter": .bool(true),
                "levels": .array([.string("max"), .string("low")])
            ])]),
            qualification: nil
        )
        // then
        #expect(facts.effort == .init(acceptsParameter: true, levels: ["max", "low"]))
    }

    @Test
    func givenQualificationShapes_whenDecoded_thenGateFollowsTheModelSelectionRow() {
        // given
        let ready = JSONValue.object(["ok": .bool(true), "source": .string("auto-probed")])
        let unsupported = JSONValue.object(["ok": .bool(false), "source": .string("unsupported")])
        let okButUnknown = JSONValue.object(["ok": .bool(true), "source": .string("unknown")])
        let unknownSource = JSONValue.object(["ok": .bool(true), "source": .string("telepathy")])
        // when / then
        #expect(gate(nil) == .notDeclared)
        #expect(gate(ready) == .ready)
        #expect(gate(.object(["ok": .bool(true), "source": .string("seeded")])) == .ready)
        #expect(gate(unsupported) == .notReady)
        #expect(gate(okButUnknown) == .notReady)
        #expect(gate(unknownSource) == .notReady)
        #expect(gate(.string("garbage")) == .notReady)
        #expect(gate(.object([:])) == .notReady)
    }

    @Test
    func givenUnavailableOrMalformedQualification_whenDecoded_thenGateIsUnknown() {
        // given
        let unavailable = JSONValue.object([
            "features": .object([:]),
            "unavailable_reason": .string("harness binary not found")
        ])
        // when / then
        #expect(entry(capabilities: nil, qualification: unavailable).modelSelection == .unknown)
        #expect(entry(capabilities: nil, qualification: .string("nope")).modelSelection == .unknown)
        #expect(entry(capabilities: nil, qualification: .object([:])).modelSelection == .unknown)
        #expect(entry(capabilities: nil, qualification: .object(["features": .array([])])).modelSelection == .unknown)
        #expect(entry(capabilities: nil, qualification: .object(["features": .object([:])])).modelSelection == .notDeclared)
    }

    @Test
    func givenExplicitNullUnavailableReason_whenDecoded_thenItReadsAsAbsent() {
        // given
        let document = JSONValue.object(["features": .object([:]), "unavailable_reason": .null])
        // when / then
        #expect(entry(capabilities: nil, qualification: document).modelSelection == .notDeclared)
    }
}
