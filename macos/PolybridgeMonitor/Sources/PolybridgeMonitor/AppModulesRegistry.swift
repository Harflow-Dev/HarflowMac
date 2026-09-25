//
//  AppModulesRegistry.swift
//  PolybridgeMonitor
//
//  The module-registration pattern: every module this app has, registered in one place. Order is lowest-layer-first (decision 13 in the settled plan,
//  matching the package graph in `macos/AGENTS.md`): `PbRepository` before `PbTerminal` (PbTerminal
//  reads repositories back out of `GlobalValues`), both before the three feature modules (their
//  `ViewRepository`s read repositories and `TerminalSessionRegistry` the same way). Order among the
//  three feature modules does not matter — none reads another's `GlobalValues` entry — so they are
//  listed in the same order the old `AppModel.init()` registered them, for continuity.
//
//  Neither `PbFoundation` package (`PbUtilities`, `PbCommon`, `PbUI`) nor `MonitorCore` has a
//  `Module` of its own — none of them registers anything into `GlobalValues`.
//

import MainWindowFeature
import MenuBarFeature
import PbRepository
import PbTerminal
import PbUtilities
import SettingsFeature

// MARK: - AppModulesRegistry

/// Every application module, in the order `ApplicationModules` must initialize them.
enum AppModulesRegistry {
    @MainActor
    static let allModules: [any PbModuleDelegate] = [
        PbRepository.Module(),
        PbTerminal.Module(),
        SettingsFeature.Module(),
        MenuBarFeature.Module(),
        MainWindowFeature.Module()
    ]
}
