//
//  MainWindowNavigationCoordinatorMock.swift
//  MainWindowFeature
//

#if DEBUG

import Combine
import Foundation
import PbCommon
import PbUtilities
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
    var path: [PathDestination] { [] }
    
    var selection: MonitorDestination?
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never> { Empty().eraseToAnyPublisher() }
    
    var isNewSessionPresented = false
    func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never> { Empty().eraseToAnyPublisher() }
    
    func handle(path _: any PathDestination) {}
    
    func buildSidebarView() -> AnyView { SidebarView(SidebarViewModelMock()).eraseToAnyView() }
    func buildNewSessionView() -> AnyView { NewSessionView(NewSessionViewModelMock()).eraseToAnyView() }
    func buildParallelView(name: String) -> AnyView { Text("Parallel: \(name)").eraseToAnyView() }
    func buildTaskDetailView(id: String) -> AnyView { Text("Task: \(id)").eraseToAnyView() }
    func buildInteractiveView(id: UUID) -> AnyView { Text("Interactive: \(id)").eraseToAnyView() }
    
    func start() -> AnyView { MainWindowNavigationView(self).eraseToAnyView() }
}

#endif
