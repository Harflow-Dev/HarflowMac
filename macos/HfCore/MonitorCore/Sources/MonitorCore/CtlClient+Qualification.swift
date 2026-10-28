import Foundation

// MARK: - CtlClient qualification

public extension CtlClient {
    /// Reads required task features without initiating qualification or permission negotiation.
    func taskQualificationPlan(options: [String]) async -> Result<BackendQualificationPlan, ToolError> {
        await qualificationPlan(command: "permission-preview", options: options)
    }

    /// Reads every engine-declared workflow candidate without initiating provider probes.
    func workflowQualificationPlan(name: String, options: [String]) async -> Result<BackendQualificationPlan, ToolError> {
        await qualificationPlan(command: "workflow-preview", options: options, positionals: [name])
    }

    /// Explicitly checks only the named features. Exit one carries useful failed-feature evidence;
    /// callers must refresh cached discovery and reconcile identity before adopting any success.
    func qualify(backend: String, features: [String]) async -> Result<[String: JSONValue], ToolError> {
        guard !backend.isEmpty, !features.isEmpty, features.count <= 64,
              features.allSatisfy({ !$0.isEmpty }), Set(features).count == features.count else {
            return .failure(.unreadable(tool: "harflow-ctl qualify", exitCode: 0, stderr: "qualification requires explicit unique features"))
        }
        return await raw("qualify", options: features.map { "--feature=\($0)" }, positionals: [backend],
                         timeout: Self.takeoverTimeout, requiringCapability: "backend-qualification.v1").flatMap { output in
            guard output.exitCode == 0 || output.exitCode == 1,
                  let root = CtlDocument.firstJSONObject(in: output.stdout),
                  let payload = root["result"]?.objectValue,
                  payload["backend"]?.stringValue == backend,
                  let rows = payload["features"]?.objectValue,
                  rows.count <= 64,
                  features.allSatisfy({ rows[$0].flatMap(BackendQualificationFeature.init) != nil }),
                  payload["ok"]?.boolValue != nil else {
                return .failure(.unreadable(tool: "harflow-ctl qualify", exitCode: output.exitCode, stderr: output.stderr))
            }
            return .success(payload)
        }
    }

    private func qualificationPlan(command: String, options: [String], positionals: [String] = []) async -> Result<BackendQualificationPlan, ToolError> {
        await result(command, options: options + ["--qualification-only"], positionals: positionals,
                     requiringCapability: "backend-qualification.v1").flatMap { payload in
            guard let plan = BackendQualificationPlan(payload) else {
                return .failure(.unreadable(tool: "harflow-ctl \(command)", exitCode: 0,
                                            stderr: "invalid cached qualification plan"))
            }
            return .success(plan)
        }
    }
}
