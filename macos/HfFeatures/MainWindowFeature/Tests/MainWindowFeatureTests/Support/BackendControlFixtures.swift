import HfRepository
import MonitorCore

/// Control facts mirroring what the recorded 0.0.13 `backends` document reports for each harness
/// (`MonitorCoreTests/Resources/RecordedCtl`). Keyed by name only inside tests, as fixture data.
enum BackendControlFixtures {
    private static let fullEffort = BackendControlFacts.Effort(acceptsParameter: true, levels: ["low", "medium", "high", "xhigh"])
    private static let noEffort = BackendControlFacts.Effort(acceptsParameter: false, levels: [])

    static let claude = BackendControlFacts(supportsModelSelection: true, supportsTurnCap: true, effort: fullEffort, modelSelection: .notDeclared)
    static let codex = BackendControlFacts(supportsModelSelection: true, supportsTurnCap: false, effort: fullEffort, modelSelection: .notDeclared)
    static let opencode = codex
    static let antigravity = BackendControlFacts(
        supportsModelSelection: true, supportsTurnCap: false,
        effort: .init(acceptsParameter: true, levels: ["low", "medium", "high"]), modelSelection: .notDeclared
    )
    static let cursor = BackendControlFacts(supportsModelSelection: true, supportsTurnCap: false, effort: noEffort, modelSelection: .notDeclared)
    /// Vibe 3.0.2 as recorded: `model_selection` present with source `unsupported`.
    static let vibeNotReady = BackendControlFacts(supportsModelSelection: true, supportsTurnCap: true, effort: noEffort, modelSelection: .notReady)
    /// Vibe 3.0.3 as seeded in the synthetic document.
    static let vibeReady = BackendControlFacts(supportsModelSelection: true, supportsTurnCap: true, effort: noEffort, modelSelection: .ready)
    /// Vibe whose qualification could not be read (`unavailable_reason`).
    static let vibeUnknownGate = BackendControlFacts(supportsModelSelection: true, supportsTurnCap: true, effort: noEffort, modelSelection: .unknown)

    /// The recorded facts for a backend name; claude-like for any other fixture name.
    static func facts(for backend: String) -> BackendControlFacts {
        switch backend {
        case "codex": codex
        case "opencode": opencode
        case "antigravity": antigravity
        case "cursor": cursor
        case "vibe": vibeNotReady
        default: claude
        }
    }

    /// A catalog entry carrying the recorded facts of its name.
    static func entry(_ backend: String, installed: Bool? = true, facts: BackendControlFacts? = nil) -> BackendCatalogEntry {
        BackendCatalogEntry(backend: backend, installed: installed, controls: facts ?? self.facts(for: backend))
    }
}
