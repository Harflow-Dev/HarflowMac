import Combine
import HfCommon
import HfRepository
import SwiftUI

// MARK: - MainWindowSheet

/// Mutually exclusive modal destinations presented by the main window.
public enum MainWindowSheet: String, Identifiable {
    /// Compatibility entry redirected to the inline composer.
    case newSession
    /// Chooses and launches a saved workflow.
    case workflowRunner
    /// Confirms stopping a captured standalone task.
    case stopTask

    /// Stable identity for the presented destination.
    public var id: String { rawValue }
}

// MARK: - MainWindowNavigationCoordinator

/// Navigation/view-building contract for the main window's split view. `MainWindowNavigationView`
/// (this package) is generic over this protocol, never the concrete `MainWindowCoordinator` —
/// `selection` and `presentedSheet` are the single source of truth the settled plan's
/// window/navigation seam formalises; the app target's root `AppCoordinator` (Phase 5) delegates
/// `.task`/`.group`/`.newSession` straight onto `handle(path:)` for the URL/notification/Cmd-N
/// paths it owns (see that file's header).
@MainActor
public protocol MainWindowNavigationCoordinator: ViewChildCoordinator {
    /// The selected retained destination or inline new-task composer. Window opening belongs to the parent.
    var runtimeIsReady: Bool { get }
    var runtimeSetupState: RuntimeSetupState { get }
    func performRuntimeSetup()
    /// First public listing readiness is independent of managed-runtime qualification.
    var hasLoadedWork: Bool { get }
    var loadingWorkError: String? { get }
    func retryLoadingWork()
    /// Carries the standalone task's top bar content to the principal toolbar item. The shell passes it down
    /// and never reads its contents.
    var topBar: TaskTopBarHolder { get }
    /// A single shell lifetime owns sidebar observation across expanded/collapsed composition.
    func startShellObservation()
    func stopShellObservation()
    func buildNavigationRail(expand: @escaping @MainActor () -> Void) -> AnyView
    var selection: MonitorDestination? { get set }
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never>

    /// The main window's mutually exclusive modal destination.
    var presentedSheet: MainWindowSheet? { get set }

    /// Compatibility projection of the New Session destination; false dismisses only that destination.
    var isNewSessionPresented: Bool { get set }
    func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never>

    /// Presents the saved-workflow chooser and existing launch flow independently of editor focus.
    func presentWorkflowRunner()
    /// Compatibility projection of the workflow runner destination; false dismisses only that destination.
    var isWorkflowRunnerPresented: Bool { get set }
    /// Builds the saved-workflow chooser and launch sheet.
    func buildWorkflowRunnerView() -> AnyView
    /// Builds the captured standalone Stop confirmation.
    func buildStopConfirmationView() -> AnyView
    /// Builds the retained saved-workflow chooser as a navigation destination.
    func buildWorkflowLibraryView() -> AnyView

    /// Builds retained finished-work Statistics.
    func buildStatisticsView() -> AnyView
    /// Builds read-only resource slots, retaining its reading and disclosure state.
    func buildResourceSlotsView() -> AnyView
    /// A narrow return action for the owner destination opened by Resource slots.
    var canReturnToResourceSlots: Bool { get }
    func returnToResourceSlots()
    /// Builds Needs you; `itemID` opens that request's detail.
    func buildNeedsYouView(itemID: String?) -> AnyView
    /// Builds the ready runtime start screen.
    func buildStartScreenView() -> AnyView
    /// Builds the expanded Running/Recent sidebar.
    func buildSidebarView() -> AnyView
    /// Builds the main window title's connection indicator.
    func buildConnectionStatusView() -> AnyView
    /// Builds the retained inline new-task composer.
    func buildNewSessionView() -> AnyView
    /// Builds the Parallel screen for the group named `name`.
    func buildParallelView(name: String) -> AnyView
    /// Builds the task detail screen for `id`.
    func buildTaskDetailView(id: String) -> AnyView
    /// Builds the workflow library and execution monitor.
    func buildWorkflowEditorView(name: String?) -> AnyView
    /// Builds the monitor for a persisted workflow run.
    func buildWorkflowRunView(id: String) -> AnyView
}

public extension MainWindowNavigationCoordinator {
    var runtimeIsReady: Bool { true }
    var runtimeSetupState: RuntimeSetupState { runtimeIsReady ? .ready : .checking }
    func performRuntimeSetup() {}
    var hasLoadedWork: Bool { true }
    var loadingWorkError: String? { nil }
    func retryLoadingWork() {}
    func startShellObservation() {}
    func stopShellObservation() {}
    func buildNavigationRail(expand _: @escaping @MainActor () -> Void) -> AnyView { AnyView(EmptyView()) }
    func buildStartScreenView() -> AnyView { AnyView(EmptyView()) }
    func buildConnectionStatusView() -> AnyView { AnyView(EmptyView()) }

    func buildStopConfirmationView() -> AnyView { AnyView(EmptyView()) }
    func buildStatisticsView() -> AnyView { AnyView(EmptyView()) }
    func buildResourceSlotsView() -> AnyView { AnyView(EmptyView()) }
    var canReturnToResourceSlots: Bool { false }
    func returnToResourceSlots() {}
    func buildNeedsYouView(itemID: String?) -> AnyView { AnyView(EmptyView()) }

    /// Derives modal state for lightweight preview and test coordinators.
    var presentedSheet: MainWindowSheet? {
        get {
            if isNewSessionPresented { return .newSession }
            return isWorkflowRunnerPresented ? .workflowRunner : nil
        }
        set {
            isNewSessionPresented = newValue == .newSession
            isWorkflowRunnerPresented = newValue == .workflowRunner
        }
    }
}
