import Foundation
import MonitorCore
import PbCommon
import PbUI

// MARK: - Sidebar Backends presentation

extension SidebarPresentationBuilder {

    /// Tabs = "All" + every backend polybridge reports (registry order) + any backend seen only in
    /// task history (alphabetical) — Design point 3/Review round 1 item 5. Also applies the
    /// selection fallback-to-"All" rule (a backend that disappears from both the catalog and
    /// history) and the degraded-with-nothing-carried-over note.
    mutating func recomputeBackendTabs() {
        var seen = Set<String>()
        var candidates: [BackendTab] = []
        for entry in latestCatalog.entries {
            guard seen.insert(entry.backend).inserted else { continue }
            candidates.append(BackendTab(id: entry.backend, isNotFound: entry.installed == false))
        }
        let historyOnly = Set(latestTasks.map(\.backend)).subtracting(seen).sorted()
        for backend in historyOnly {
            candidates.append(BackendTab(id: backend, isNotFound: false))
        }
        // Most-used first (task count in the listing); ties keep the order above — registry order,
        // then history-only names alphabetically.
        var usage: [String: Int] = [:]
        for task in latestTasks { usage[task.backend, default: 0] += 1 }
        let ranked = candidates.enumerated()
            .sorted { lhs, rhs in
                let left = usage[lhs.element.id] ?? 0, right = usage[rhs.element.id] ?? 0
                return left == right ? lhs.offset < rhs.offset : left > right
            }
            .map(\.element)
        let tabs: [BackendTab] = [.all] + ranked
        backendTabs = tabs

        if !tabs.contains(where: { $0.id == selectedBackend }) { selectedBackend = "all" }

        catalogUnavailableNote = (latestCatalog.state == .degraded && latestCatalog.entries.isEmpty)
            ? "Backend list unavailable — update polybridge."
            : nil
    }
}
