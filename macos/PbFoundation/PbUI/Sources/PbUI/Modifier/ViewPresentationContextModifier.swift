//
//  ViewPresentationContextModifier.swift
//  PbUI
//
//  Window-scoped alerts, dialogs and actionable workflow incidents. Incidents are consumed
//  synchronously by the environment binding so multiple publications in one render frame are
//  never collapsed into the latest event. Durable outcome messages remain view model state.
//

import AppKit
import PbCommon
import SwiftUI

// MARK: - ViewPresentationContextModifier

struct ViewPresentationContextModifier: ViewModifier {
    
    @State private var viewEvent: ViewEvent = .none
    @State private var incidents = IncidentPresentation()
    @State private var interacting = false
    @State private var detailsPresented = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let clock = Timer.publish(every: 0.25, on: .main, in: .common).autoconnect()
    
    init(incidents: IncidentPresentation = IncidentPresentation()) {
        _incidents = State(initialValue: incidents)
    }

    private var presentationBinding: Binding<ViewEvent> {
        Binding(get: { viewEvent }, set: { event in
            switch event {
            case .incident, .incidentResolved: handleIncident(event)
            default: viewEvent = event
            }
        })
    }

    func body(content: Content) -> some View {
        content
            .environment(\.viewEvent, presentationBinding)
            .overlay(alignment: .top) { snackbar }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: incidents.current?.id)
            .overlay(alignment: .bottomTrailing) { retainedDetails }
            .onReceive(clock) { now in incidents.tick(now: now, paused: interacting || !NSApp.isActive) }
            .alert(
                viewEvent.alert?.title ?? "",
                isPresented: Binding(
                    get: { viewEvent.alert != nil },
                    set: { if !$0 { viewEvent = .none } }
                ),
                presenting: viewEvent.alert
            ) { alert in
                ForEach(alert.actions, id: \.self) { action in
                    Button(action.title, role: action.role, action: action.action)
                }
            } message: { alert in
                if let description = alert.description {
                    Text(description)
                }
            }
            .confirmationDialog(
                viewEvent.dialog?.title ?? "",
                isPresented: Binding(
                    get: { viewEvent.dialog != nil },
                    set: { if !$0 { viewEvent = .none } }
                ),
                titleVisibility: .visible,
                presenting: viewEvent.dialog
            ) { dialog in
                ForEach(dialog.actions, id: \.self) { action in
                    Button(action.title, role: action.role, action: action.action)
                }
            } message: { dialog in
                if let description = dialog.description {
                    Text(description)
                }
            }
    }

    @ViewBuilder private var snackbar: some View {
        if let incident = incidents.current {
            IncidentSnackbar(incident: incident, dismiss: { incidents.dismiss() }, interaction: { interacting = $0 })
                .id(incident.id)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder private var retainedDetails: some View {
        if !incidents.failures.isEmpty {
            Button("Workflow errors (\(incidents.failures.count))") { detailsPresented = true }
                .buttonStyle(.bordered)
.padding(8)
                .popover(isPresented: $detailsPresented) {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(incidents.failures) { failure in
                            Text(failure.message).textSelection(.enabled)
                            if let retry = failure.retry { Button(retry.title, action: retry.action) }
                        }
                        Text("Workflow reads retry automatically.").foregroundStyle(.secondary)
                    }
.padding()
.frame(width: 380)
                }
        }
    }

    private func handleIncident(_ event: ViewEvent) {
        switch event {
        case .incident(let source, let message, let retry):
            guard incidents.report(source: source, message: message, retry: retry) else { return }
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                                 userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        case .incidentResolved(let source): incidents.resolve(source: source)
        default: break
        }
    }

}

public extension View {
    /// Injects the shared ``ViewEvent`` presentation context into the view hierarchy: makes
    /// `@Environment(\.viewEvent)` available to descendants, renders native alerts/dialogs, and
    /// processes every workflow incident or recovery even when events share a render frame.
    /// Apply this once per scene (Settings included).
    func withPresentationContext() -> some View {
        modifier(ViewPresentationContextModifier())
    }
}

#if DEBUG

// MARK: - Preview

@MainActor
@Observable
private final class DummyPresentationVM: ViewModel {
    var index: Int = 0
    
    func sendEvent() {
        index += 1
        switch index % 3 {
        case 1:
            publishAlert("Lorem ipsum", description: "Lorem ipsum dolor sit amet.") {
                AlertAction(title: "OK")
                AlertAction(title: "Cancel", role: .cancel)
            }
        case 2:
            publishDialog("Cancel this task?", description: "polybridge stops the run and every live sub-task.") {
                AlertAction(title: "Cancel task", role: .destructive)
            }
        default:
            flushViewEvent()
        }
    }
}

private struct DummyPresentationView: View {
    @Environment(\.viewEvent) var viewEvent: Binding<ViewEvent>
    @State var vm = DummyPresentationVM()
    
    var body: some View {
        Button("Trigger next event") { vm.sendEvent() }
            .padding()
            .publishViewEvent(from: vm, to: viewEvent)
    }
}

#Preview {
    DummyPresentationView()
        .withPresentationContext()
}
#endif
