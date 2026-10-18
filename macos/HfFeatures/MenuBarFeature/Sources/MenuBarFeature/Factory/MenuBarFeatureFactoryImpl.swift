//
//  MenuBarFeatureFactoryImpl.swift
//  MenuBarFeature
//

import HfCommon

// MARK: - MenuBarFeatureFactoryImpl

/// The real `MenuBarFeatureFactory`, registered into `GlobalValues` by `Module`.
public struct MenuBarFeatureFactoryImpl: MenuBarFeatureFactory {
    
    public init() {}
    
    @MainActor
    public func makeMenuBarCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator {
        MenuBarCoordinator(parent: parent)
    }
}
