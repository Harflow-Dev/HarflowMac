import Foundation
import MonitorCore

/// Injectable asynchronous boundary for store readers; the argument is the selected absolute root.
public typealias StoreCompatibilityCheck = @Sendable (String) async -> Result<Void, ToolError>

/// Uses the selected runtime without discovery or filesystem access. Managed tooling fails here.
enum StoreCompatibility {
    static func check(toolEnvironment: any ToolEnvironmentRepository, expectedStateRoot: String,
                      requiring: Set<WireContract>) async -> Result<Void, ToolError> {
        guard LexicalStateRoot.normalize(expectedStateRoot) != nil else {
            return .failure(WireEnvelope.incompatibility("reader requires an absolute state_root"))
        }
        switch toolEnvironment.ctl() {
        case .failure(let error): return .failure(error)
        case .success(let client): return await client.checkCompatibility(expectedStateRoot: expectedStateRoot, requiring: requiring)
        }
    }
}
