//
//  SettingsFeatureFactory.swift
//  PbCommon
//
//  See MainWindowFeatureFactory.swift for the pattern this mirrors.
//

import Foundation
import Mockable
import PbUtilities
import SwiftEnvironment
import SwiftUI

// MARK: - SettingsFeatureFactory

/// A factory contract for building the Settings scene's coordinator subtree.
@Mockable
public protocol SettingsFeatureFactory: Sendable {

    /// Creates the Settings coordinator as a child of the specified parent coordinator.
    /// - Parameter parent: The parent coordinator.
    /// - Returns: A view-child coordinator for the Settings subtree.
    @MainActor
    func makeSettingsCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator
}

// MARK: - DummySettingsFeatureFactory

/// A dummy Settings factory used as a default/fallback in the global environment.
public struct DummySettingsFeatureFactory: SettingsFeatureFactory {

    /// Initializes a dummy Settings factory.
    public init() {}

    /// Creates a placeholder Settings coordinator.
    /// - Parameter parent: The parent coordinator.
    /// - Returns: A placeholder view-child coordinator.
    @MainActor
    public func makeSettingsCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator {
        DummyChildCoordinator(parent: parent)
    }
}

// MARK: - Extensions

public extension GlobalValues {

    /// Global environment entry for `SettingsFeatureFactory`.
    @GlobalEntry var settingsFeatureFactory: any SettingsFeatureFactory = DummySettingsFeatureFactory()
}
