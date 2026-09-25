//
//  MainWindowNavigationView.swift
//  MainWindowFeature
//
//  The main window's `NavigationSplitView`, moved here from the app target's `MainView.swift` with
//  no behaviour change: the sidebar and the detail pane come from the coordinator, the detail switch
//  mirrors the old `switch model.selection` exactly (same empty-detail state, same closed-terminal
//  fallback for a missing/closed interactive session — now `InteractiveView`'s own job), and the New
//  Session sheet is bound to `isNewSessionPresented`. Generic over `MainWindowNavigationCoordinator`,
//  never the concrete `MainWindowCoordinator`, so a preview (or a future test) can supply a stub.
//
//  `withPresentationContext()` (PbUI) is applied exactly once, here at the window root — moved out of
//  `MainWindowCoordinator.buildParallelView(name:)`/`buildTaskDetailView(id:)`, which used to apply it
//  themselves (each screen its own isolated environment/state) because nothing above them owned a
//  scene yet. Every screen under this view now shares the one `@Environment(\.viewEvent)` this root
//  provides, including the New Session sheet, which SwiftUI carries the presenting view's environment
//  into.
//

import PbCommon
import PbUI
import PbUtilities
import SwiftUI

// MARK: - MainWindowNavigationView

struct MainWindowNavigationView<Coordinator: MainWindowNavigationCoordinator>: View {
    
    // MARK: - State
    
    @State var coordinator: Coordinator
    
    // MARK: - Init
    
    init(_ coordinator: Coordinator) {
        _coordinator = State(initialValue: coordinator)
    }
    
    // MARK: - View Body
    
    var body: some View {
        NavigationSplitView {
            coordinator.buildSidebarView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } detail: {
            switch coordinator.selection {
            case .task(let id):
                coordinator.buildTaskDetailView(id: id)
            case .group(let name):
                coordinator.buildParallelView(name: name)
            case .interactive(let id):
                coordinator.buildInteractiveView(id: id)
            case .newSession, .openWindow, nil:
                emptyDetailView
            }
        }
        .sheet(isPresented: Binding(get: { coordinator.isNewSessionPresented }, set: { coordinator.isNewSessionPresented = $0 })) {
            coordinator.buildNewSessionView()
        }
        .frame(minWidth: 1000, minHeight: 620)
        .withPresentationContext()
    }
    
    // MARK: - Private Views
    
    private var emptyDetailView: some View {
        VStack(spacing: 8) {
            Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 32)).foregroundStyle(.secondary)
            Text("Select a task").font(.headline)
            Text("Tasks started through polybridge show up in the sidebar, live.").foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if DEBUG
#Preview {
    MainWindowNavigationView(MainWindowNavigationCoordinatorMock())
}
#endif
