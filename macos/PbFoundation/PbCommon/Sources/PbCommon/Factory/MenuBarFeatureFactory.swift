//
//  MenuBarFeatureFactory.swift
//  PbCommon
//
//  See MainWindowFeatureFactory.swift for the pattern this mirrors.
//

import Foundation
import Mockable
import PbUtilities
import SwiftEnvironment
import SwiftUI

// MARK: - MenuBarFeatureFactory

/// A factory contract for building the menu bar's coordinator subtree.
@Mockable
public protocol MenuBarFeatureFactory: Sendable {

    /// Creates the menu bar coordinator as a child of the specified parent coordinator.
    /// - Parameter parent: The parent coordinator.
    /// - Returns: A view-child coordinator for the menu bar subtree.
    @MainActor
    func makeMenuBarCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator
}

// MARK: - DummyMenuBarFeatureFactory

/// A dummy menu bar factory used as a default/fallback in the global environment.
public struct DummyMenuBarFeatureFactory: MenuBarFeatureFactory {

    /// Initializes a dummy menu bar factory.
    public init() {}

    /// Creates a placeholder menu bar coordinator.
    /// - Parameter parent: The parent coordinator.
    /// - Returns: A placeholder view-child coordinator.
    @MainActor
    public func makeMenuBarCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator {
        DummyChildCoordinator(parent: parent)
    }
}

// MARK: - Extensions

public extension GlobalValues {

    /// Global environment entry for `MenuBarFeatureFactory`.
    @GlobalEntry var menuBarFeatureFactory: any MenuBarFeatureFactory = DummyMenuBarFeatureFactory()
}
