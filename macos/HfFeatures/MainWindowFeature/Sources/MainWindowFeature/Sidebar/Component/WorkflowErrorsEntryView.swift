import HfCommon
import HfUI
import SwiftUI

// MARK: - WorkflowErrorsEntryView

/// A sidebar-owned entry into the window's retained actionable workflow failures.
struct WorkflowErrorsEntryView: View {
    @Environment(\.incidentPresentation) private var incidents
    @State private var detailsPresented = false

    var body: some View {
        if let incidents {
            Group {
                if !incidents.failures.isEmpty {
                    Button { detailsPresented = true } label: {
                        HStack(spacing: HfRadius.Metrics.spacing8) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.failedRed)
                            Text("Workflow errors")
                            Spacer(minLength: HfRadius.Metrics.zero)
                            Text("\(incidents.failures.count)").monospacedDigit()
                        }
                        .font(.hf(.secondary, weight: .semibold))
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Workflow errors (\(incidents.failures.count))")
                    .accessibilityIdentifier("sidebar-workflow-errors")
                    .padding(.top, HfRadius.Metrics.spacing8)
                    .popover(isPresented: $detailsPresented, arrowEdge: .bottom) { details(incidents) }
                }
            }
            .onChange(of: incidents.failures.isEmpty) { _, empty in
                if empty { detailsPresented = false }
            }
        }
    }

    private func details(_ incidents: IncidentPresentation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                ForEach(incidents.failures) { failure in
                    Text(failure.message).textSelection(.enabled)
                    if let retry = failure.retry {
                        Button(retry.title) {
                            // A read may replace its operation-bound closure while this popover stays open.
                            incidents.failures.first { $0.id == failure.id }?.retry?.action()
                        }
                    }
                    Divider()
                }
                Text("Workflow reads retry automatically.").foregroundStyle(Color.secondaryText)
            }
            .font(.hf(.body))
            .padding(HfRadius.Metrics.spacing16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ActivityScrollChrome())
        }
        .frame(width: HfRadius.Metrics.workflowErrorsPopoverWidth)
        .frame(maxHeight: HfRadius.Metrics.workflowErrorsPopoverMaximumHeight)
        .accessibilityIdentifier("workflow-errors-details")
    }
}

#if DEBUG
private struct WorkflowErrorsPreview: View {
    let count: Int
    @State private var incidents = IncidentPresentation()

    var body: some View {
        VStack(spacing: HfRadius.Metrics.spacing8) {
            Spacer()
            WorkflowErrorsEntryView()
            HStack {
                SidebarAppearanceControl(appearance: .system, onSelect: { _ in })
                Spacer()
                Image(systemName: "gearshape")
            }
        }
        .padding(HfRadius.Metrics.spacing16)
        .frame(width: 272, height: 180)
        .background(Color.inspectorFill)
        .environment(\.incidentPresentation, incidents)
        .onAppear {
            for index in 0 ..< count {
                incidents.report(source: "preview-\(index)", message: "Could not refresh workflow \(index + 1).",
                                 retry: AlertAction(title: "Retry workflow read", action: {}))
            }
        }
    }
}

#Preview("No workflow errors light") { WorkflowErrorsPreview(count: 0).preferredColorScheme(.light) }
#Preview("No workflow errors dark") { WorkflowErrorsPreview(count: 0).preferredColorScheme(.dark) }
#Preview("One workflow error light") { WorkflowErrorsPreview(count: 1).preferredColorScheme(.light) }
#Preview("One workflow error dark") { WorkflowErrorsPreview(count: 1).preferredColorScheme(.dark) }
#Preview("Several workflow errors light") { WorkflowErrorsPreview(count: 3).preferredColorScheme(.light) }
#Preview("Several workflow errors dark") { WorkflowErrorsPreview(count: 3).preferredColorScheme(.dark) }
#endif
