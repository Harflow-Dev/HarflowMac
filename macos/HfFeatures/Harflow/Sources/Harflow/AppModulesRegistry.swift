//
//  AppModulesRegistry.swift
//  Harflow
//
//  The module-registration pattern: every module this app has, registered in one place. Order is
//  lowest-layer-first (decision 13 in the settled plan, matching the package graph in
//  `macos/AGENTS.md`): `HfRepository` before the three feature modules (their `ViewRepository`s read
//  repositories back out of `GlobalValues`). Order among the three feature modules does not matter
//  — none reads another's `GlobalValues` entry — so they are listed in the same order the old
//  `AppModel.init()` registered them, for continuity.
//
//  Neither `HfFoundation` package (`HfUtilities`, `HfCommon`, `HfUI`) nor `MonitorCore` has a
//  `Module` of its own — none of them registers anything into `GlobalValues`.
//

import HfRepository
import HfUtilities
import MainWindowFeature
import MenuBarFeature
import SettingsFeature

// MARK: - AppModulesRegistry

/// Every application module, in the order `ApplicationModules` must initialize them.
enum AppModulesRegistry {
    @MainActor
    static let allModules: [any HfModuleDelegate] = [
        HfRepository.Module(),
        SettingsFeature.Module(),
        MenuBarFeature.Module(),
        MainWindowFeature.Module()
    ]
}
