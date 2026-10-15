import MonitorCore
import SwiftUI

// MARK: - TaskArtifactsView

struct TaskArtifactsView: View {
    let members: [ArtifactMemberModel]
    let load: (String) -> Void

    var body: some View {
        if !members.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("Registered artifacts").font(.headline)
                Text("Agent-registered metadata, separate from edited files and task success. Availability is an observation at the time shown.")
                    .font(.caption)
.foregroundStyle(.secondary)
                ForEach(members) { member in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source task: " + member.id).font(.caption).textSelection(.enabled)
                        if let count = member.count { Text("\(count) registered").font(.caption) }
                        ForEach(member.items) { item in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(verbatim: item.note).textSelection(.enabled)
                                    Text(verbatim: item.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                    Text("Artifact: " + item.artifactID).textSelection(.enabled)
                                    Text("Registrar: " + item.registrar + " · " + item.taskID)
                                    Text("Registered: " + item.registeredAt)
                                    Text("Observed: " + item.observedAt)
                                }.font(.caption)
                            } label: {
                                Text(item.kind + " · " + item.availability)
                            }
                        }
                        if let message = member.message { Text(message).font(.caption).textSelection(.enabled) }
                        if member.loaded, member.items.isEmpty, member.message == nil { Text("No registered artifacts.").font(.caption) }
                        Button(buttonTitle(member)) {
                            load(member.id)
                        }.disabled(member.loading)
                    }
                }
            }
        }
    }

    private func buttonTitle(_ member: ArtifactMemberModel) -> String {
        if member.loading { return "Loading…" }
        if member.hasMore { return "Load more artifacts" }
        return member.loaded ? "Refresh artifacts" : "Load artifact metadata"
    }
}

#if DEBUG
#Preview {
    TaskArtifactsView(members: [ArtifactMemberModel(id: "example-task")], load: { _ in }).padding()
}
#endif
