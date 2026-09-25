import Foundation

// MARK: - RepoPathFormat

/// Duplicated from `PbUI.Format.repo` (`Style.swift:134-137`). `PbRepository` is a Core-layer
/// package and must not depend on `PbUI` (a Foundation/UI-layer package) — see the root AGENTS.md's
/// package graph. `MonitorCore` has no equivalent helper. This is flagged in the Phase 3
/// implementation report rather than duplicated silently, per the plan's instructions; a test in
/// this package pins this copy's behaviour so a future divergence between the two is caught.
///
/// Made `public` in Phase 3 part B: `PbTerminal` is also a Core-layer package and needs the same
/// formatting for an interactive session's title (`"<backend> · <repo, formatted>"`), and must not
/// depend on `PbUI` either. Reusing this copy avoids a *third* copy; see the Phase 3B report.
public enum RepoPathFormat {
    public static func repo(_ path: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}
