//
//  FakeMainWindowNavigationCoordinator.swift
//  PolybridgeMonitorTests
//
//  `MainWindowNavigationCoordinator` is not itself `@Mockable` (only the plain
//  `MainWindowFeatureFactory`/`Coordinator` protocols are), so — same reason
//  `PbCommonTestMock.ViewChildCoordinatorMock` exists for the `ViewChildCoordinator` typealias — this
//  is a small hand-written fake standing in for a real `MainWindowCoordinator` in `AppCoordinator`
//  tests.
//

import Combine
import Foundation
import MainWindowFeature
import PbCommon
import PbUtilities
import SwiftUI

@MainActor
@Observable
final class FakeMainWindowNavigationCoordinator: MainWindowNavigationCoordinator {
    
    let parent: any Coordinator
    var path: [PathDestination] { [] }
    
    var selection: MonitorDestination?
    var isNewSessionPresented = false
    
    /// Every `MonitorDestination` this fake was asked to `handle(path:)`, in order — so a test can
    /// assert both the resulting state *and* that delegation actually happened (rather than the
    /// state merely matching by coincidence).
    private(set) var handledDestinations: [MonitorDestination] = []

    /// Fired synchronously at the top of `handle(path:)`, before any state changes — lets a test
    /// append to a shared event log (alongside `AppCoordinator`'s `activateApp`/window-opener log) to
    /// prove cross-type ordering, e.g. "activate → opener → forwarded to `MainWindowCoordinator`" for
    /// `.newSession` (decision 5).
    var onHandle: ((MonitorDestination) -> Void)?

    init(parent: any Coordinator) {
        self.parent = parent
    }
    
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never> { Empty().eraseToAnyPublisher() }
    func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never> { Empty().eraseToAnyPublisher() }
    func buildSidebarView() -> AnyView { EmptyView().eraseToAnyView() }
    func buildNewSessionView() -> AnyView { EmptyView().eraseToAnyView() }
    func buildParallelView(name: String) -> AnyView { EmptyView().eraseToAnyView() }
    func buildTaskDetailView(id: String) -> AnyView { EmptyView().eraseToAnyView() }
    func start() -> AnyView { EmptyView().eraseToAnyView() }

    func handle(path: any PathDestination) {
        guard let destination = path as? MonitorDestination else { return }
        onHandle?(destination)
        handledDestinations.append(destination)
        switch destination {
        case .task, .group, .workflow, .newWorkflow, .workflowRun: selection = destination
        case .newSession: isNewSessionPresented = true
        case .openWindow: parent.handle(path: destination)
        }
    }
}
