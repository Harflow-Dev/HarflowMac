import SwiftUI

// MARK: - IncidentSnackbar

struct IncidentSnackbar: View {
    let incident: IncidentPresentation.Incident
    let dismiss: () -> Void
    let interaction: (Bool) -> Void
    @State private var hovered = false
    private enum Focus: Hashable { case details, dismiss }
    @FocusState private var focused: Focus?
    @State private var details = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(incident.message).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            Button("Details") { details = true }
                .focused($focused, equals: .details)
                .popover(isPresented: $details) { Text(incident.message).textSelection(.enabled).padding().frame(width: 360) }
            Button(action: dismiss) { Image(systemName: "xmark") }
                .accessibilityLabel("Dismiss notification")
                .focused($focused, equals: .dismiss)
        }
        .font(.pb(.body))
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.secondary.opacity(0.25)))
        .shadow(radius: 6, y: 2)
        .frame(maxWidth: 640)
        .padding(12)
        .onHover { hovered = $0; interaction(hovered || focused != nil || details) }
        .onChange(of: focused) { _, _ in interaction(hovered || focused != nil || details) }
        .onChange(of: details) { _, _ in interaction(hovered || focused != nil || details) }
        .onDisappear { interaction(false) }
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
#Preview {
    IncidentSnackbar(incident: .init(source: "workflow-list", message: "Workflow list unavailable"), dismiss: {}, interaction: { _ in })
}
#endif
