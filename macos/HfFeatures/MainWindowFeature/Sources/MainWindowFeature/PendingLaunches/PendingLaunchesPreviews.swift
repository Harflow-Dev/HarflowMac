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
        repoPath: String? = "/projects/Harflow", resources: [String] = [], reason: String? = nil,
        cancelSupport: String = "supported", createdAt: String? = "2026-11-10T09:30:00Z"
    ) -> TaskPendingLaunchItem {
        func text(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
        var raw: [String: JSONValue] = ["task_id": .string(id), "disposition": .string(disposition)]
        if disposition == "pending" {
            raw["cancel_support"] = .string(cancelSupport)
            raw["launch"] = .object([
                "generation": .string(String(repeating: "a", count: 32)), "state": .string(state),
                "title": text(title), "backend": text(backend), "repo_path": text(repoPath),
                "created_at": text(createdAt), "not_started_reason": text(reason),
                "lineage": .object([:]), "resource_names": .array(resources.map(JSONValue.string)), "metadata_truncated": .bool(false)
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

    /// An exact-lookup value for `item`, as the engine would answer it.
    static func lookup(_ item: TaskPendingLaunchItem) -> TaskPendingLaunchLookup {
        var raw = item.raw
        raw["scope"] = .string(TaskPendingLaunchWire.scope)
        raw["observed_at"] = .string("2026-11-10T09:31:00Z")
        return TaskPendingLaunchLookup(raw: raw, requestedTaskID: item.taskID)!
    }

    /// A recorded, not-found or refused lookup answer for `id`.
    static func plainLookup(id: String, disposition: String) -> TaskPendingLaunchLookup {
        var raw: [String: JSONValue] = ["task_id": .string(id), "disposition": .string(disposition)]
        if disposition == "refused" || disposition == "unknown" {
            raw["code"] = .string("synthetic")
            raw["check"] = .string("synthetic")
        }
        return lookup(TaskPendingLaunchItem(raw: raw)!)
    }

    static let inventory = PendingLaunchesPresentation.make(
        .init(runtimeIdentity: UUID(), inventory: .init(rows: items, completedCheck: true)), leaseRefused: false
    )
}

@MainActor
private func pendingPreview(_ presentation: PendingLaunchesPresentation, detail: PendingLaunchDetailPresentation? = nil) -> some View {
    PendingLaunchesContent(presentation: presentation, detail: detail).frame(width: 850, height: 620)
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

// MARK: - Detail states

extension PendingLaunchesFixture {
    static let detailID = "20261110-093000-a17c92"

    /// Every selected-launch state, keyed by its name, as the mapping produces it.
    static func detail(_ state: String, busy: Bool = false) -> PendingLaunchDetailPresentation {
        let id = detailID
        var flags = PendingLaunchDetailFlags(firstCheckSettled: true, handoffFailed: state == "handoff-failed", isBusy: busy)
        let evidence: PendingLaunchDetailPresentation.Evidence
        switch state {
        case "checking":
            flags.firstCheckSettled = false
            evidence = .none
        case "waiting": evidence = .value(lookup(item(id: id, resources: ["Claude slots", "Shared checkout"])))
        case "preparing": evidence = .value(lookup(item(id: id, state: "claimed")))
        case "preparing-handshake":
            evidence = .value(lookup(item(id: id, state: "claimed", backend: "codex", cancelSupport: "unsupported")))
        case "granted": evidence = .value(lookup(item(id: id, state: "granted")))
        case "not-started":
            evidence = .value(lookup(item(id: id, state: "not_started", reason: "resource wait was cancelled")))
        case "unavailable": evidence = .failed
        case "missing": evidence = .value(plainLookup(id: id, disposition: "not_found"))
        default: evidence = .value(plainLookup(id: id, disposition: "recorded"))
        }
        return .make(taskID: id, evidence: evidence, flags: flags)
    }

    static let detailStates = ["checking", "waiting", "preparing", "preparing-handshake", "granted", "not-started",
                               "unavailable", "missing", "recorded", "handoff-failed"]
}

@MainActor
private func detailPreview(_ state: String, _ scheme: ColorScheme) -> some View {
    pendingPreview(PendingLaunchesFixture.inventory, detail: PendingLaunchesFixture.detail(state)).preferredColorScheme(scheme)
}

#Preview("Detail waiting light") { detailPreview("waiting", .light) }
#Preview("Detail waiting dark") { detailPreview("waiting", .dark) }
#Preview("Detail preparing light") { detailPreview("preparing", .light) }
#Preview("Detail handshake light") { detailPreview("preparing-handshake", .light) }
#Preview("Detail granted light") { detailPreview("granted", .light) }
#Preview("Detail not started light") { detailPreview("not-started", .light) }
#Preview("Detail unavailable light") { detailPreview("unavailable", .light) }
#Preview("Detail missing light") { detailPreview("missing", .light) }
#Preview("Detail recorded light") { detailPreview("recorded", .light) }
#Preview("Detail handoff failed light") { detailPreview("handoff-failed", .light) }
#Preview("Detail checking light") { detailPreview("checking", .light) }
#Preview("Detail checking dark") { detailPreview("checking", .dark) }
#endif
