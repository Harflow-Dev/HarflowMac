//
//  MainWindowFeatureFactory.swift
//  PbCommon
//
//  The feature-factory pattern (features never import each other; each exposes a factory here),
//  kept to the minimal surface MainWindowFeature needs. Fleshed out in Phase 4/5 — this only
//  declares the seam and a dummy default so `@GlobalEntry` resolves before the real factory is
//  registered.
//

import Foundation
import Mockable
import PbUtilities
import SwiftEnvironment
import SwiftUI

// MARK: - MainWindowFeatureFactory

/// A factory contract for building the main window's coordinator subtree.
@Mockable
public protocol MainWindowFeatureFactory: Sendable {
    
    /// Creates the main window coordinator as a child of the specified parent coordinator.
    /// - Parameter parent: The parent coordinator.
    /// - Returns: A view-child coordinator for the main window subtree.
    @MainActor
    func makeMainWindowCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator
}

// MARK: - DummyMainWindowFeatureFactory

/// A dummy main window factory used as a default/fallback in the global environment.
public struct DummyMainWindowFeatureFactory: MainWindowFeatureFactory {
    
    /// Initializes a dummy main window factory.
    public init() {}
    
    /// Creates a placeholder main window coordinator.
    /// - Parameter parent: The parent coordinator.
    /// - Returns: A placeholder view-child coordinator.
    @MainActor
    public func makeMainWindowCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator {
        DummyChildCoordinator(parent: parent)
    }
}

// MARK: - Extensions

public extension GlobalValues {
    
    /// Global environment entry for `MainWindowFeatureFactory`.
    @GlobalEntry var mainWindowFeatureFactory: any MainWindowFeatureFactory = DummyMainWindowFeatureFactory()
}
