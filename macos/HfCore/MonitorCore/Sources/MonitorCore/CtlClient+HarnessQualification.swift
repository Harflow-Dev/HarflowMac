import Foundation

// MARK: - Settings cached qualification adapter

public extension CtlClient {
    /// All feature rows declared in cached public backend metadata; never a provider probe.
    func harnessQualificationPlan(backend: String) async -> Result<BackendQualificationPlan, ToolError> {
        await raw("backends", requiringCapability: "backend-qualification.v1").flatMap { output in
            guard output.exitCode == 0,
                  let document = CtlDocument.firstJSONObject(in: output.stdout),
                  let rows = document["backends"]?.arrayValue,
                  let row = rows.first(where: { $0["backend"]?.stringValue == backend }),
                  let qualification = row["qualification"]?.objectValue,
                  let features = qualification["features"]?.objectValue else {
                return .failure(.unreadable(tool: "harflow-ctl backends", exitCode: output.exitCode, stderr: "Missing cached harness qualification"))
            }
            var requirement: [String: JSONValue] = ["id": .string("settings/" + backend), "backend": .string(backend),
                "required_features": .array(features.keys.sorted().map(JSONValue.string)), "features": .object(features)]
            // Never infer identity from a version label. All feature rows must agree; individual
            // evidence identity checks in the plan remain authoritative.
            let identities = features.values.compactMap { $0["identity"] }
            if let first = identities.first, identities.count == features.count, identities.allSatisfy({ $0 == first }) {
                requirement["identity"] = first
            }
            if let reason = qualification["unavailable_reason"]?.stringValue {
                requirement["unavailable_reason"] = .string(String(reason.prefix(1000)))
            }
            guard let plan = BackendQualificationPlan(["qualification_version": .number(1), "discovery_only": .bool(true),
                                                       "requirements": .array([.object(requirement)])]) else {
                return .failure(.unreadable(tool: "harflow-ctl backends", exitCode: output.exitCode, stderr: "Invalid cached harness qualification"))
            }
            return .success(plan)
        }
    }
}
