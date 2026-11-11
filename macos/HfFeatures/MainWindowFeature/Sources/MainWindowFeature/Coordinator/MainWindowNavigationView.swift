import HfCommon
import HfUI
import HfUtilities
import SwiftUI

// MARK: - Native shell environment

extension EnvironmentValues {
    @Entry var toggleHarflowSidebar: (@MainActor () -> Void)?
}

// MARK: - MainWindowNavigationView

/// Approved M04 shell: HarflowDesign 5b37a3d, m04-proposal/shell and shell-collapsed.
/// Native titlebar and window controls remain owned by AppKit.
struct MainWindowNavigationView<Coordinator: MainWindowNavigationCoordinator>: View {
    @State var coordinator: Coordinator
    @State private var columns: NavigationSplitViewVisibility = .all
    /// The window width band, written on a band crossing only. The shell body never reads it; the principal and the
    /// task toolbar's chips do.
    @State private var layout = TopBarLayoutState()
    /// Native regression probes; production leaves these nil.
    private let onShellEvaluation: (() -> Void)?
    private let onPrincipalEvaluation: (() -> Void)?

    init(_ coordinator: Coordinator, sidebarCollapsed: Bool = false, onShellEvaluation: (() -> Void)? = nil,
         onPrincipalEvaluation: (() -> Void)? = nil) {
        _coordinator = State(initialValue: coordinator)
        _columns = State(initialValue: sidebarCollapsed ? .detailOnly : .all)
        self.onShellEvaluation = onShellEvaluation
        self.onPrincipalEvaluation = onPrincipalEvaluation
    }

    private var isCollapsed: Bool { columns == .detailOnly }

    var body: some View {
        _ = onShellEvaluation?()
        return HStack(spacing: 0) {
            if isCollapsed {
                coordinator.buildNavigationRail { columns = .all }
                Divider()
            }
            NavigationSplitView(columnVisibility: $columns) {
                coordinator.buildSidebarView()
                    .toolbar(removing: .sidebarToggle)
                    .navigationSplitViewColumnWidth(min: 264, ideal: 264, max: 320)
                    .environment(\.toggleHarflowSidebar, { columns = .detailOnly })
            } detail: {
                detail
            }
        }
        .onGeometryChange(for: TopBarWidthBand.self) { TopBarWidthBand(width: $0.size.width) } action: { layout.setBand($0) }
        .environment(\.topBarLayout, layout)
        .toolbar {
            if coordinator.canReturnToResourceSlots {
                ToolbarItem(placement: .navigation) {
                    Button("Back to resource slots", systemImage: "chevron.left", action: coordinator.returnToResourceSlots)
                }
            }
            ToolbarItem(placement: .principal) {
                TaskTopBarPrincipal(holder: coordinator.topBar, layout: layout, fallbackTitle: contextTitle,
                                    status: coordinator.buildConnectionStatusView(), onEvaluation: onPrincipalEvaluation)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .sheet(item: Binding(get: {
            coordinator.presentedSheet == .newSession ? nil : coordinator.presentedSheet
        }, set: { coordinator.presentedSheet = $0 }), onDismiss: { coordinator.pendingLaunchStopSheetDidDismiss() }) { sheet in
            switch sheet {
            case .workflowRunner: coordinator.buildWorkflowRunnerView()
            case .stopTask: coordinator.buildStopConfirmationView()
            case .stopPendingLaunch: coordinator.buildPendingLaunchStopView()
            case .newSession: EmptyView()
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .toolbar(removing: .title)
        .withPresentationContext()
        .onAppear { coordinator.startShellObservation() }
        .onDisappear { coordinator.stopShellObservation() }
    }

    @ViewBuilder private var detail: some View {
        if !coordinator.runtimeIsReady {
            RuntimeSetupWelcomeView(state: coordinator.runtimeSetupState, action: coordinator.performRuntimeSetup)
        } else {
            switch coordinator.selection {
            case .statistics: coordinator.buildStatisticsView()
            case .resourceSlots: coordinator.buildResourceSlotsView()
            case .pendingLaunches: coordinator.buildPendingLaunchesView()
            case .needsYou(let id): coordinator.buildNeedsYouView(itemID: id)
            case .task(let id): coordinator.buildTaskDetailView(id: id)
            case .group(let name): coordinator.buildParallelView(name: name)
            case .workflow(let name): coordinator.buildWorkflowEditorView(name: name)
            case .workflowLibrary: coordinator.buildWorkflowLibraryView()
            case .newWorkflow(let id): coordinator.buildWorkflowEditorView(name: nil).id(id)
            case .workflowRun(let id): coordinator.buildWorkflowRunView(id: id)
            case .newSession, .openWindow, nil:
                if coordinator.hasLoadedWork {
                    coordinator.buildNewSessionView()
                } else {
                    InitialWorkLoadingView(error: coordinator.loadingWorkError, retry: coordinator.retryLoadingWork)
                }
            }
        }
    }

    private var contextTitle: String {
        guard coordinator.runtimeIsReady else { return "Harflow · Runtime setup" }
        switch coordinator.selection {
        case .statistics: return "Harflow · Statistics"
        case .resourceSlots: return "Harflow · Resources"
        case .pendingLaunches: return "Harflow · Pending launches"
        case .needsYou: return "Harflow · Needs you"
        case .workflow, .workflowLibrary, .newWorkflow, .workflowRun: return "Harflow · Workflows"
        case .task, .group: return "Harflow · Work"
        default: return "Harflow · New task"
        }
    }

}

#if DEBUG
#Preview {
    MainWindowNavigationView(MainWindowNavigationCoordinatorMock())
}
#endif
