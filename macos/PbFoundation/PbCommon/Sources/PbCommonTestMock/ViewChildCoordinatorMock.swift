//
//  ViewChildCoordinatorMock.swift
//  PbCommonTestMock
//
//  `Mockable` cannot
//  generate a mock directly for a typealias (`ViewChildCoordinator = ChildCoordinator & ViewCoordinator`),
//  so this restates its requirements as one protocol to mock.
//

import Foundation
import Mockable
import PbCommon
import SwiftUI

// MARK: - ViewChildCoordinatorMock

/// A mock protocol that combines `ViewChildCoordinator` requirements for Mockable.
@Mockable
public protocol ViewChildCoordinatorMock: ViewChildCoordinator {
    
    /// The parent coordinator.
    @MainActor var parent: Coordinator { get }
    
    /// The coordinator path.
    @MainActor var path: [PathDestination] { get }
    
    /// The full path including children.
    @MainActor var fullPath: [PathDestination] { get }
    
    /// Produces the root view for the child coordinator.
    @MainActor func start() -> AnyView
    
    /// Produces the root view for a path.
    @MainActor func start(with path: PathDestination) -> AnyView
    
    /// Handles a URL.
    @MainActor @discardableResult func handle(url: URL) -> Bool
    
    /// Handles a path destination.
    @MainActor func handle(path: PathDestination)
    
    /// Restarts the coordinator.
    @MainActor func restart()
    
    @MainActor func stop()
}
