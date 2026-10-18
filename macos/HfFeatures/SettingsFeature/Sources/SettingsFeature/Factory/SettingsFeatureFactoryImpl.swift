//
//  SettingsFeatureFactoryImpl.swift
//  SettingsFeature
//

import HfCommon

// MARK: - SettingsFeatureFactoryImpl

/// The real `SettingsFeatureFactory`, registered into `GlobalValues` by `Module`.
public struct SettingsFeatureFactoryImpl: SettingsFeatureFactory {
    
    public init() {}
    
    @MainActor
    public func makeSettingsCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator {
        SettingsCoordinator(parent: parent)
    }
}
