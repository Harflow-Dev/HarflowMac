//
//  DummyChildCoordinator.swift
//  PbCommon
//
//  Used as the `@GlobalEntry` default for every feature factory protocol below, and directly in previews.
//

import Dummyable
import Foundation
import PbUtilities
import SwiftUI

// MARK: - DummyCoordinator

/// A no-op root coordinator for use in previews and debug fixtures.
@Dummyable
@Observable
public final class DummyCoordinator: Coordinator {
    
    // MARK: - Public Properties
    
    /// The coordinator path.
    public var path: [PathDestination] = []
    
    // MARK: - Initializer
    
    /// Initializes a dummy coordinator.
    @DummyableInit
    public init() {}
    
    // MARK: - Public Methods
    
    /// Handles a URL — always returns false.
    @MainActor
    public func handle(url _: URL) -> Bool { false }
    
    /// Handles a navigation path — no-op.
    @MainActor
    public func handle(path _: any PathDestination) {}
    
    /// Restarts the dummy coordinator — no-op.
    @MainActor
    public func restart() {}
    
    /// Stops the dummy coordinator — no-op.
    @MainActor
    public func stop() {}
}

// MARK: - DummyChildCoordinator

/// A no-op view-child coordinator used by dummy feature factories.
@MainActor
@Observable
public final class DummyChildCoordinator: ViewChildCoordinator {
    
    // MARK: - Public Properties
    
    /// The parent coordinator.
    public let parent: any Coordinator
    
    /// The path representing the coordinator's current position in the navigation tree.
    public var path: [PathDestination] { [] }
    
    // MARK: - Initializer
    
    /// Initializes a dummy child coordinator.
    /// - Parameter parent: The parent coordinator.
    public init(parent: any Coordinator) {
        self.parent = parent
    }
    
    // MARK: - Public Methods
    
    /// Produces an empty placeholder root view.
    public func start() -> AnyView {
        EmptyView().eraseToAnyView()
    }
    
    /// Handles a navigation path — no-op.
    public func handle(path _: any PathDestination) {}
}
