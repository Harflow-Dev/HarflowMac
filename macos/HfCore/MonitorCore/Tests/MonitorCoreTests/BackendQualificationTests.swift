import Foundation
@testable import MonitorCore
import Testing

struct BackendQualificationTests {
    private func identity(digest: String = String(repeating: "a", count: 64)) -> JSONValue {
        .object(["backend": .string("codex"), "version": .string("fixture"),
                 "executable": .string("/fixture/codex"), "binary_sha256": .string(digest),
                 "platform": .string("darwin-arm64")])
    }

    private func requirement(source: String = "seeded", ok: Bool = true,
                             featureIdentity: JSONValue? = nil) -> JSONValue {
        .object(["id": .string("candidate"), "backend": .string("codex"),
                 "required_features": .array([.string("write")]), "identity": identity(),
                 "features": .object(["write": .object(["ok": .bool(ok), "source": .string(source),
                                                        "identity": featureIdentity ?? identity()])])])
    }

    @Test func givenSeededAndMeasuredEvidence_whenRequiredIdentityMatches_thenReady() {
        // given / when / then
        for source in ["seeded", "auto-probed"] {
            #expect(BackendQualificationRequirement(requirement(source: source))?.isReady == true)
        }
    }

    @Test func givenRuntimeFailure_whenSuccessFlagRemainsTrue_thenNotReady() {
        // given / when / then
        #expect(BackendQualificationRequirement(requirement(source: "failed-at-runtime"))?.isReady == false)
        #expect(BackendQualificationRequirement(requirement(source: "failed", ok: false))?.isReady == false)
    }

    @Test func givenReplacedBinary_whenCachedEvidenceHasOldDigest_thenNotReady() {
        // given
        let oldIdentity = identity(digest: String(repeating: "b", count: 64))
        // when
        let candidate = BackendQualificationRequirement(requirement(featureIdentity: oldIdentity))
        // then
        #expect(candidate?.isReady == false)
    }

    @Test func givenMissingEvidenceIdentity_whenFeatureClaimsSuccess_thenNotReady() {
        // given / when / then
        #expect(BackendQualificationRequirement(requirement(featureIdentity: .null))?.isReady == false)
    }

    @Test func givenUnknownSource_whenDecoding_thenRejectRatherThanGuess() {
        // given / when / then
        #expect(BackendQualificationRequirement(requirement(source: "future-success")) == nil)
    }

    @Test func givenUnsupportedOrProbingPlan_whenDecoding_thenReject() {
        // given
        let payload: [String: JSONValue] = ["qualification_version": .number(1), "discovery_only": .bool(true),
                                            "requirements": .array([requirement()])]
        // when / then
        #expect(BackendQualificationPlan(payload)?.isReady == true)
        var unsupported = payload
        unsupported["qualification_version"] = .number(2)
        #expect(BackendQualificationPlan(unsupported) == nil)
        unsupported = payload
        unsupported["discovery_only"] = .bool(false)
        #expect(BackendQualificationPlan(unsupported) == nil)
    }

    @Test func givenDuplicateCandidates_whenDecoding_thenReject() {
        // given / when / then
        #expect(BackendQualificationPlan(["qualification_version": .number(1), "discovery_only": .bool(true),
                                          "requirements": .array([requirement(), requirement()])]) == nil)
    }

    @Test func givenNoRequiredFeatures_whenIdentityAbsent_thenQualificationSatisfiedUnlessExplicitlyUnavailable() {
        // given
        var row: [String: JSONValue] = ["id": .string("plain"), "backend": .string("fixture"),
                                         "required_features": .array([]), "features": .object([:])]
        // when / then
        #expect(BackendQualificationRequirement(.object(row))?.isReady == true)
        row["unavailable_reason"] = .string("Explicit engine refusal")
        #expect(BackendQualificationRequirement(.object(row))?.isReady == false)
    }

    @Test func givenEngineQualificationFixture_whenDecoded_thenUnknownEvidenceStaysUnavailable() throws {
        // given
        let url = try #require(Bundle.module.url(forResource: "ctl-backend-qualification", withExtension: "json", subdirectory: "ContractsV1"))
        let wire = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
        // when
        let payload = try #require(wire["result"]?.objectValue)
        let plan = try #require(BackendQualificationPlan(payload))
        let requirement = try #require(plan.requirements.first)
        let feature = try #require(requirement.features["caller_approval_tools"])
        // then
        #expect(requirement.id == "task")
        #expect(requirement.requiredFeatures == ["caller_approval_tools"])
        #expect(feature.source == .unknown)
        #expect(feature.identity == requirement.identity)
        #expect(!plan.isReady)
    }

}
