import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowChildLink

struct WorkflowChildLink: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let ordinal: Int
}

// MARK: - WorkflowChildLinkGroup

struct WorkflowChildLinkGroup: Identifiable, Equatable {
    let id: String
    let name: String
    var runs: [WorkflowChildLink]

    static func build(run: WorkflowRunModel) -> [Self] {
        var groups: [Self] = []
        var seen = Set<String>()
        for activation in run.activations {
            guard let invocation = activation["invocation"]?.objectValue,
                  let childID = invocation["child_workflow_run_id"]?.stringValue,
                  !childID.isEmpty, seen.insert(childID).inserted else { continue }
            let rawName = invocation["workflow_name"]?.stringValue ?? ""
            let name = rawName.isEmpty ? "Child workflow" : rawName
            // Names alone must not merge different saved workflow identities.
            let workflowID = invocation["workflow_id"]?.stringValue ?? ""
            let key = workflowID.isEmpty ? "run:\(childID)" : "workflow:\(workflowID)"
            let index: Int
            if let existing = groups.firstIndex(where: { $0.id == key }) {
                index = existing
            } else {
                groups.append(Self(id: key, name: name, runs: []))
                index = groups.count - 1
            }
            let status = activation["node_result"]?["result"]?["child_outcome"]?["child_status"]?.stringValue
                ?? invocation["stage"]?.stringValue ?? "unknown"
            groups[index].runs.append(WorkflowChildLink(id: childID, name: name, status: status,
                                                        ordinal: groups[index].runs.count + 1))
        }
        return groups
    }
}

// MARK: - WorkflowChildLinks

struct WorkflowChildLinks: View {
    let groups: [WorkflowChildLinkGroup]
    let onOpen: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expandedIDs: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(groups) { group in
                if group.runs.count > 1 {
                    DisclosureGroup(isExpanded: Binding(get: { expandedIDs.contains(group.id) }, set: { expanded in
                        withAnimation(PbMotion.disclosure(reduceMotion: reduceMotion)) {
                            if expanded { expandedIDs.insert(group.id) } else { expandedIDs.remove(group.id) }
                        }
                    })) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(group.runs) { link in row(link, repeated: true) }
                        }.padding(.top, 4)
                    } label: {
                        Text("\(group.name) · \(group.runs.count) runs")
                            .font(.pb(.secondary, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let link = group.runs.first {
                    row(link, repeated: false)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ link: WorkflowChildLink, repeated: Bool) -> some View {
        Button { onOpen(link.id) } label: {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repeated ? "Run \(link.ordinal) · \(link.name)" : link.name)
                        .font(.pb(.secondary, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(link.status.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Select \(link.name), run \(link.ordinal), \(link.status) · \(link.id)")
        .accessibilityLabel("Select child workflow \(link.name), run \(link.ordinal), \(link.status)")
        .accessibilityIdentifier("child-workflow-link-\(link.id)")
    }
}

#if DEBUG
#Preview {
    WorkflowChildLinks(groups: [WorkflowChildLinkGroup(id: "child", name: "Review", runs: [
        WorkflowChildLink(id: "one", name: "Review", status: "completed", ordinal: 1),
        WorkflowChildLink(id: "two", name: "Review", status: "running", ordinal: 2)
    ])], onOpen: { _ in })
.padding()
.frame(width: 320)
}
#endif
