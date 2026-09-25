//
//  FakeMainWindowNavigationCoordinator.swift
//  PolybridgeMonitorTests
//
//  `MainWindowNavigationCoordinator` is not itself `@Mockable` (only the plain
//  `MainWindowFeatureFactory`/`Coordinator` protocols are), so — same reason
//  `PbCommonTestMock.ViewChildCoordinatorMock` exists for the `ViewChildCoordinator` typealias — this
//  is a small hand-written fake standing in for a real `MainWindowCoordinator` in `AppCoordinator`
//  tests, without dragging in `PbTerminal`'s `TerminalSessionRegistry` wiring a real one needs.
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
    
    init(parent: any Coordinator) {
        self.parent = parent
    }
    
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never> { Empty().eraseToAnyPublisher() }
    func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never> { Empty().eraseToAnyPublisher() }
    func buildSidebarView() -> AnyView { EmptyView().eraseToAnyView() }
    func buildNewSessionView() -> AnyView { EmptyView().eraseToAnyView() }
    func buildParallelView(name: String) -> AnyView { EmptyView().eraseToAnyView() }
    func buildTaskDetailView(id: String) -> AnyView { EmptyView().eraseToAnyView() }
    func buildInteractiveView(id: UUID) -> AnyView { EmptyView().eraseToAnyView() }
    func start() -> AnyView { EmptyView().eraseToAnyView() }
    
    func handle(path: any PathDestination) {
        guard let destination = path as? MonitorDestination else { return }
        handledDestinations.append(destination)
        switch destination {
        case .task, .group, .interactive: selection = destination
        case .newSession: isNewSessionPresented = true
        case .openWindow: parent.handle(path: destination)
        }
    }
}
