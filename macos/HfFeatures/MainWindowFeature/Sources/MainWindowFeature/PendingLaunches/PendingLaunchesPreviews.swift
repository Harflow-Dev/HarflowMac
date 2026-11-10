#if DEBUG
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - PendingLaunchesFixture

/// Synthetic values for previews and tests; nothing here touches an engine or real state.
enum PendingLaunchesFixture {
    static func item(
        id: String, disposition: String = "pending", state: String = "waiting_for_resources",
        title: String? = "Review launch admission checks", backend: String? = "claude",
        repoPath: String? = "/projects/Harflow"
    ) -> TaskPendingLaunchItem {
        func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        var raw: [String: JSONValue] = ["task_id": .string(id), "disposition": .string(disposition)]
        if disposition == "pending" {
            raw["cancel_support"] = .string("supported")
            raw["launch"] = .object([
                "generation": .string(String(repeating: "a", count: 32)), "state": .string(state),
                "title": text(title), "backend": text(backend), "repo_path": text(repoPath),
                "created_at": .string("2026-11-10T09:30:00Z"), "not_started_reason": .null,
                "lineage": .object([:]), "resource_names": .array([]), "metadata_truncated": .bool(false)
            ])
        } else {
            raw["code"] = .string("synthetic")
            raw["check"] = .string("synthetic")
        }
        return TaskPendingLaunchItem(raw: raw)!
    }

    static let items = [
        item(id: "20261110-093000-a17c92"),
        item(id: "20261110-093200-b28d03", state: "claimed", title: "Prepare local environment", backend: "codex")
    ]

    static let inventory = PendingLaunchesPresentation.make(
        .init(runtimeIdentity: UUID(), inventory: .init(rows: items, completedCheck: true)), leaseRefused: false
    )
}

@MainActor
private func pendingPreview(_ presentation: PendingLaunchesPresentation) -> some View {
    PendingLaunchesContent(presentation: presentation, onCheckAgain: {}).frame(width: 850, height: 620)
}

private func presentation(_ inventory: PendingLaunchInventory, refused: Bool = false) -> PendingLaunchesPresentation {
    .make(.init(runtimeIdentity: UUID(), inventory: inventory), leaseRefused: refused)
}

private let previewIncomplete = presentation(.init(rows: PendingLaunchesFixture.items, failure: .incomplete))

#Preview("Inventory light") { pendingPreview(PendingLaunchesFixture.inventory).preferredColorScheme(.light) }
#Preview("Inventory dark") { pendingPreview(PendingLaunchesFixture.inventory).preferredColorScheme(.dark) }
#Preview("Loading light") { pendingPreview(presentation(.init())).preferredColorScheme(.light) }
#Preview("Loading dark") { pendingPreview(presentation(.init())).preferredColorScheme(.dark) }
#Preview("Empty light") { pendingPreview(presentation(.init(completedCheck: true))).preferredColorScheme(.light) }
#Preview("Empty dark") { pendingPreview(presentation(.init(completedCheck: true))).preferredColorScheme(.dark) }
#Preview("Failed light") { pendingPreview(presentation(.init(failure: .unavailable))).preferredColorScheme(.light) }
#Preview("Failed dark") { pendingPreview(presentation(.init(failure: .unavailable))).preferredColorScheme(.dark) }
#Preview("Incomplete light") { pendingPreview(previewIncomplete).preferredColorScheme(.light) }
#Preview("Incomplete dark") { pendingPreview(previewIncomplete).preferredColorScheme(.dark) }
#endif
