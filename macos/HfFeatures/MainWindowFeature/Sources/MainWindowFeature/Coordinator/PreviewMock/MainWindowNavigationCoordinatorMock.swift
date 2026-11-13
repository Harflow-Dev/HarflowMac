//
//  MainWindowNavigationCoordinatorMock.swift
//  MainWindowFeature
//

#if DEBUG

import Combine
import Foundation
import HfCommon
import HfRepository
import HfUtilities
import SwiftUI

// MARK: - MainWindowNavigationCoordinatorMock

/// Preview mock for `MainWindowNavigationView`. Builds the real `SidebarView`/`NewSessionView` (so
/// the split view itself previews faithfully) but plain placeholder text for the other screens —
/// those already have their own dedicated previews, and pulling in every screen's own mock here would
/// only make this one more fragile to change elsewhere.
@MainActor
@Observable
final class MainWindowNavigationCoordinatorMock: MainWindowNavigationCoordinator {
    
    let parent: any Coordinator = DummyCoordinator()
    let topBar = TaskTopBarHolder()
    var path: [PathDestination] { [] }
    
    var selection: MonitorDestination?
    var runtimeIsReady: Bool
    var hasLoadedWork = true
    var loadingWorkError: String?
    var listingRetryCount = 0
    func retryLoadingWork() { listingRetryCount += 1 }
    let composerViewModel = NewSessionViewModelMock()
    var optionsInitiallyPresented = false
    let retainedTaskViewModel = TaskDetailViewModelMock()
    func performRuntimeSetup() { sidebarViewModel.didTapRuntimeSetup() }
    /// One retained sidebar VM, so a `runtimeSetupState` change reaches the mounted `SidebarView`
    /// (which holds its VM in `@State`) the way the production VM's published state does.
    let sidebarViewModel: SidebarViewModelMock
    var runtimeSetupState: RuntimeSetupState {
        get { sidebarViewModel.runtimeSetupState }
        set { sidebarViewModel.runtimeSetupState = newValue }
    }

    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never> { Empty().eraseToAnyPublisher() }
    
    var isNewSessionPresented = false
    /// Lets an integrated test present the standalone Stop confirmation under the real shell. It builds the sheet through
    /// `stopConfirmationBuilder`, which defaults to an empty view like every other coordinator that has no Stop sheet.
    var isStopConfirmationPresented = false
    @ObservationIgnored var stopConfirmationBuilder: (@MainActor () -> AnyView)?
    func buildStopConfirmationView() -> AnyView { stopConfirmationBuilder?() ?? AnyView(EmptyView()) }
    var presentedSheet: MainWindowSheet? {
        get {
            if isStopConfirmationPresented { return .stopTask }
            if isNewSessionPresented { return .newSession }
            return isWorkflowRunnerPresented ? .workflowRunner : nil
        }
        set {
            isStopConfirmationPresented = newValue == .stopTask
            isNewSessionPresented = newValue == .newSession
            isWorkflowRunnerPresented = newValue == .workflowRunner
        }
    }

    func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never> { Empty().eraseToAnyPublisher() }
    
    func handle(path _: any PathDestination) {}
    
    func buildSidebarView() -> AnyView {
        SidebarView(sidebarViewModel).eraseToAnyView()
    }

    func buildNavigationRail(expand: @escaping @MainActor () -> Void) -> AnyView {
        SidebarNavigationRail(sidebarViewModel, expand: expand).eraseToAnyView()
    }

    func buildConnectionStatusView() -> AnyView {
        ConnectionStatusView(ConnectionStatusPreviewMock()).eraseToAnyView()
    }

    func buildPendingLaunchesView() -> AnyView { PendingLaunchesView(PendingLaunchesPreviewMock()).eraseToAnyView() }
    func buildNewSessionView() -> AnyView { NewSessionView(composerViewModel, optionsPresented: optionsInitiallyPresented).eraseToAnyView() }
    @ObservationIgnored var parallelBuilder: (@MainActor (String) -> AnyView)?
    func buildParallelView(name: String) -> AnyView { parallelBuilder?(name) ?? Text("Parallel: \(name)").eraseToAnyView() }
    /// Lets an integrated test mount a different task view (for example the standalone one) under the real shell.
    @ObservationIgnored var taskDetailBuilder: (@MainActor (String) -> AnyView)?
    func buildTaskDetailView(id: String) -> AnyView {
        taskDetailBuilder?(id) ?? TaskDetailView(retainedTaskViewModel).eraseToAnyView()
    }

    /// Shows the shell's "Back to resource slots" toolbar item when true.
    var resourceReturnAvailable = false
    var canReturnToResourceSlots: Bool { resourceReturnAvailable }
    func returnToResourceSlots() {}
    
    func start() -> AnyView { MainWindowNavigationView(self).eraseToAnyView() }

    init(
        runtimeIsReady: Bool = true,
        runtimeSetupState: RuntimeSetupState = .ready
    ) {
        self.runtimeIsReady = runtimeIsReady
        self.sidebarViewModel = SidebarViewModelMock(runtimeSetupState: runtimeSetupState)
    }
}

#endif
