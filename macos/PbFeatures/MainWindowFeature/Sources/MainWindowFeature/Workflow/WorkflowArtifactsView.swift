import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowArtifactsView

struct WorkflowArtifactsView: View {
    let model: WorkflowArtifactModel
    let load: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            SectionLabel(text: "Artifacts")
            Text("Registered references; content has not been validated.")
                .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
            ForEach(model.items) { item in
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                    Text(item.kind + " · " + item.path).textSelection(.enabled)
                    Text(item.note).textSelection(.enabled)
                    if item.availability != "available" {
                        Text(item.availability.capitalized).foregroundStyle(Color.secondaryText)
                    }
                    if item.workflow?.attribution == "native_transport" {
                        Text("Native transport · child authorship is not attributed").foregroundStyle(Color.secondaryText)
                    }
                }.font(.pb(.caption))
            }
            ForEach(Array(model.owners.enumerated()), id: \.offset) { _, owner in
                Text(owner.state == "record_removed" ? "Owner record removed" : "Unavailable: owner references")
                    .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
            }
            if let message = model.message { Text(message).font(.pb(.caption)).foregroundStyle(Color.secondaryText) }
            if model.loaded, model.items.isEmpty, model.owners.isEmpty, model.message == nil {
                Text("No registered references").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
            Button(model.loading ? "Loading…" : model.hasMore ? "Load more artifacts" : model.loaded ? "Refresh artifacts" : "Load artifacts", action: load)
                .buttonStyle(QuietButtonStyle())
.disabled(model.loading)
        }
    }
}

#if DEBUG
#Preview { WorkflowArtifactsView(model: WorkflowArtifactModel(), load: {}).padding() }
#endif
