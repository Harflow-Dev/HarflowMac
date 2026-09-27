//
//  AppModulesRegistryTests.swift
//  PolybridgeMonitorTests
//
//  The module registration order and wiring test named in the Phase 5 brief's item 6. `.serialized`
//  and save/restore: every touched `GlobalValues` entry is captured before the suite runs and put
//  back afterward, closing the "GlobalValues saved and restored" gap Phase 4b's own Codex review
//  flagged (and left unfixed, as a repo-wide convention change out of that dispatch's scope) — this
//  is a fresh, app-shell-owned test file, so it can do it properly from the start.
//

import MainWindowFeature
import MenuBarFeature
import MonitorCore
import PbCommon
import PbRepository
import PbUtilities
@testable import PolybridgeMonitor
import SettingsFeature
import SwiftEnvironment
import Testing

@MainActor
@Suite(.serialized)
struct AppModulesRegistryTests {

    @Test func givenAppModulesRegistry_whenInspected_thenModulesAreOrderedLowestLayerFirst() {
        // given / when
        let modules = AppModulesRegistry.allModules

        // then — PbRepository (Core) before the three Feature modules (decision 13).
        #expect(modules.count == 4)
        #expect(modules[0] is PbRepository.Module)
        #expect(modules[1] is SettingsFeature.Module)
        #expect(modules[2] is MenuBarFeature.Module)
        #expect(modules[3] is MainWindowFeature.Module)
    }

    @Test func givenAllModules_whenInitialized_thenGlobalValuesResolveToRealImplementations() {
        // given
        let snapshot = GlobalValuesSnapshot()
        defer { snapshot.restore() }

        // when
        ApplicationModules(modules: AppModulesRegistry.allModules).initialize()

        // then — every entry a module in this registry registers no longer resolves to its `Null*`/
        // `Dummy*` default. Reading each keeps the assertion honest about *which* value changed,
        // rather than asserting the type once and hoping every dependency followed.
        #expect(!(GlobalValues.taskListRepository is NullTaskListRepository))
        #expect(!(GlobalValues.settingsRepository is NullSettingsRepository))
        #expect(!(GlobalValues.taskActionRepository is NullTaskActionRepository))
        #expect(!(GlobalValues.eventStreamRepository is NullEventStreamRepository))
        #expect(!(GlobalValues.taskSnapshotRepository is NullTaskSnapshotRepository))
        #expect(!(GlobalValues.takeoverService is NullTakeoverService))
        #expect(!(GlobalValues.backendsRepository is NullBackendsRepository))
        #expect(GlobalValues.settingsFeatureFactory is SettingsFeatureFactoryImpl)
        #expect(GlobalValues.menuBarFeatureFactory is MenuBarFeatureFactoryImpl)
        #expect(GlobalValues.mainWindowFeatureFactory is MainWindowFeatureFactoryImpl)
    }
}

/// Captures every `GlobalValues` entry `AppModulesRegistry.allModules` can register, and restores it
/// on `restore()`. `SwiftEnvironment.GlobalValues` has no public save/restore API of its own (`reset()`
/// is package-internal), so this reads the pre-test value for each key path and re-assigns it —
/// the same shape every `Module.initializeModule()` already uses to write one.
@MainActor
private struct GlobalValuesSnapshot {
    private let taskListRepository = GlobalValues.taskListRepository
    private let settingsRepository = GlobalValues.settingsRepository
    private let toolEnvironmentRepository = GlobalValues.toolEnvironmentRepository
    private let taskSnapshotRepository = GlobalValues.taskSnapshotRepository
    private let eventStreamRepository = GlobalValues.eventStreamRepository
    private let finishNotifier = GlobalValues.finishNotifier
    private let taskActionRepository = GlobalValues.taskActionRepository
    private let harnessRepository = GlobalValues.harnessRepository
    private let scheduling = GlobalValues.scheduling
    private let takeoverService = GlobalValues.takeoverService
    private let backendsRepository = GlobalValues.backendsRepository
    private let settingsFeatureFactory = GlobalValues.settingsFeatureFactory
    private let menuBarFeatureFactory = GlobalValues.menuBarFeatureFactory
    private let mainWindowFeatureFactory = GlobalValues.mainWindowFeatureFactory
    
    func restore() {
        GlobalValues
            .environment(\.taskListRepository, taskListRepository)
            .environment(\.settingsRepository, settingsRepository)
            .environment(\.toolEnvironmentRepository, toolEnvironmentRepository)
            .environment(\.taskSnapshotRepository, taskSnapshotRepository)
            .environment(\.eventStreamRepository, eventStreamRepository)
            .environment(\.finishNotifier, finishNotifier)
            .environment(\.taskActionRepository, taskActionRepository)
            .environment(\.harnessRepository, harnessRepository)
            .environment(\.scheduling, scheduling)
            .environment(\.takeoverService, takeoverService)
            .environment(\.backendsRepository, backendsRepository)
            .environment(\.settingsFeatureFactory, settingsFeatureFactory)
            .environment(\.menuBarFeatureFactory, menuBarFeatureFactory)
            .environment(\.mainWindowFeatureFactory, mainWindowFeatureFactory)
    }
}
