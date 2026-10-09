import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowPermissionPreview

struct WorkflowPermissionPreview: Equatable {
    let hash: String
    let permissions: WorkflowPermissionsModel

    init?(_ response: [String: JSONValue]) {
        guard let hash = response["preview_hash"]?.stringValue, !hash.isEmpty,
              let contracts = response["owner_contracts"]?.objectValue,
              let permissions = WorkflowPermissionsModel(contracts) else { return nil }
        self.hash = hash
        self.permissions = permissions
    }
}

// MARK: - WorkflowPermissionsModel

struct WorkflowPermissionsModel: Equatable {
    struct Candidate: Identifiable, Equatable {
        let id: String
        let title: String
        let access: String
        let network: String
        let contributingNodes: [String]
        let fallbacks: [String]
    }

    let candidates: [Candidate]

    init?(_ contracts: [String: JSONValue]) {
        guard contracts["version"]?.stringValue == "native_owner_contract_v1",
              let owners = contracts["owners"]?.objectValue else { return nil }
        var result: [Candidate] = []
        for ownerID in owners.keys.sorted() {
            guard let owner = owners[ownerID]?.objectValue, let plans = owner["candidates"]?.objectValue else { continue }
            for key in plans.keys.sorted() {
                guard let plan = plans[key]?.objectValue,
                      let freedom = plan["freedom"]?.stringValue else { continue }
                let candidate = plan["candidate"]?.objectValue ?? [:]
                let backend = candidate["backend"]?.stringValue ?? "Agent"
                let model = candidate["model"]?.stringValue
                let title = (owner["name"]?.stringValue ?? ownerID) + " · " + backend + (model.map { " · " + $0 } ?? "")
                let contributors = Set(WorkflowJSON.objects(plan["contributing_nodes"]).map(Self.nodeCandidateIdentity))
                let nodes = WorkflowJSON.objects(plan["nodes"])
                let names = nodes.filter { contributors.contains(Self.nodeCandidateIdentity($0)) }
                    .map { $0["title"]?.stringValue ?? $0["node_id"]?.stringValue ?? "Node" }
                let fallbacks = nodes.compactMap { node -> String? in
                    guard let reason = node["fallback_reason"]?.stringValue else { return nil }
                    let title = node["title"]?.stringValue ?? node["node_id"]?.stringValue ?? "Node"
                    guard let candidate = node["candidate"]?.objectValue else { return title + ": " + reason }
                    let position = node["candidate_position"]?.intValue ?? 0
                    let role = position == 0 ? "primary" : "fallback \(position)"
                    let harness = candidate["backend"]?.stringValue ?? "Agent"
                    let model = candidate["model"]?.stringValue.map { " · " + $0 } ?? ""
                    return title + " · " + role + " · " + harness + model + ": " + reason
                }
                let network = plan["network"]?.boolValue.map { $0 ? "Requested on" : "Requested off" } ?? "Harness default request"
                result.append(Candidate(id: ownerID + ":" + key, title: title,
                                        access: WorkflowAccess.title(freedom), network: network,
                                        contributingNodes: Array(Set(names)).sorted(), fallbacks: fallbacks))
            }
        }
        guard !result.isEmpty else { return nil }
        self.candidates = result
    }

    private static func nodeCandidateIdentity(_ node: [String: JSONValue]) -> String {
        let position = node["candidate_position"]?.intValue.map(String.init) ?? "legacy"
        let candidate = node["candidate"]?.rendered() ?? "legacy"
        return (node["workflow_id"]?.stringValue ?? "") + ":" + (node["node_id"]?.stringValue ?? "") + ":" + position + ":" + candidate
    }
}

// MARK: - WorkflowPermissionsView

struct WorkflowPermissionsView: View {
    let model: WorkflowPermissionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "Orchestrator permissions")
            Text("The orchestrator receives these permissions so its native children can perform their work.")
            ForEach(model.candidates) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.title).font(.pb(.secondary, weight: .semibold))
                    Text("\(candidate.access) · Network: \(candidate.network)")
                    Text("Network enforcement depends on the harness.")
                    if candidate.contributingNodes.isEmpty {
                        Text("No native workers expand this orchestrator's access.")
                    } else {
                        Text("Required by: " + candidate.contributingNodes.joined(separator: ", "))
                    }
                    if !candidate.fallbacks.isEmpty {
                        DisclosureGroup("Headless workers") {
                            ForEach(Array(candidate.fallbacks.enumerated()), id: \.offset) { _, reason in Text(reason) }
                        }
                    }
                }
            }
        }
        .font(.pb(.caption))
        .foregroundStyle(Color.secondaryText)
        .textSelection(.enabled)
    }
}

#if DEBUG
#Preview("Orchestrator permissions") {
    WorkflowPermissionsView(model: WorkflowPermissionsModel([
        "version": .string("native_owner_contract_v1"),
        "owners": .object(["root": .object([
            "name": .string("Implementation"), "candidates": .object(["codex": .object([
                "candidate": .object(["backend": .string("codex")]),
                "freedom": .string("write_in_repo"), "network": .bool(false),
                "nodes": .array([.object(["workflow_id": .string("root"), "node_id": .string("implement"), "title": .string("Implement change")])]),
                "contributing_nodes": .array([.object(["workflow_id": .string("root"), "node_id": .string("implement")])])
            ])])
        ])])
    ])!).padding()
}
#endif
