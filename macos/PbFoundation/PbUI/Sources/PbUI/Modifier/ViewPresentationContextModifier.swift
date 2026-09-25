//
//  ViewPresentationContextModifier.swift
//  PbUI
//
//  The macOS presentation modifier for view events, limited to the two ``ViewEvent`` cases the Monitor uses (decision 10): `.alert` renders a native
//  SwiftUI `.alert`, `.dialog` a `.confirmationDialog` with each button's role (destructive/cancel)
//  preserved. Not wired into any scene yet — Phase 4/5 replaces the app's four existing
//  `confirmationDialog`s with `ViewModel.publishDialog`/`.publishAlert` and applies this once per
//  scene, per the settled plan's window/navigation seam.
//

import PbCommon
import SwiftUI

// MARK: - ViewPresentationContextModifier

private struct ViewPresentationContextModifier: ViewModifier {
    
    @State private var viewEvent: ViewEvent = .none
    
    func body(content: Content) -> some View {
        content
            .environment(\.viewEvent, $viewEvent)
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
}

public extension View {
    /// Injects the shared ``ViewEvent`` presentation context into the view hierarchy: makes
    /// `@Environment(\.viewEvent)` available to descendants, and renders `.alert`/`.dialog` events
    /// as native alerts/confirmation dialogs. Apply this once per scene (Settings included).
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
