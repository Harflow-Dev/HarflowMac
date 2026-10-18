//
//  MainWindowFeatureFactoryImpl.swift
//  MainWindowFeature
//

import PbCommon

// MARK: - MainWindowFeatureFactoryImpl

/// The real `MainWindowFeatureFactory`, registered into `GlobalValues` by `Module`.
public struct MainWindowFeatureFactoryImpl: MainWindowFeatureFactory {
    
    public init() {}
    
    @MainActor
    public func makeMainWindowCoordinator(asChildOf parent: any Coordinator) -> any ViewChildCoordinator {
        MainWindowCoordinator(parent: parent)
    }
}
