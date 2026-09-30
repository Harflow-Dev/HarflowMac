//
//  MainWindowConfiguratorTests.swift
//  PolybridgeMonitorTests
//
//  Decision 6 ("Full screen"): a pure-function test for
//  `MainWindowConfigurator.fullScreenCollectionBehavior(_:)`. A bitmask test can't prove the SwiftUI
//  window itself was configured — that's the manual ⌃⌘F check in the settled plan — but it does
//  prove the logic: incompatible flags are removed, `.fullScreenPrimary` is inserted, unrelated flags
//  survive, and applying it twice is a no-op past the first application.
//

import AppKit
@testable import PolybridgeMonitor
import Testing

@Suite struct MainWindowConfiguratorTests {

    @Test func givenFullScreenAuxiliary_whenApplied_thenItIsRemovedAndPrimaryIsInserted() {
        // given
        let behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary]

        // when
        let result = MainWindowConfigurator.fullScreenCollectionBehavior(behavior)

        // then
        #expect(!result.contains(.fullScreenAuxiliary))
        #expect(result.contains(.fullScreenPrimary))
    }

    @Test func givenFullScreenNone_whenApplied_thenItIsRemovedAndPrimaryIsInserted() {
        // given
        let behavior: NSWindow.CollectionBehavior = [.fullScreenNone]

        // when
        let result = MainWindowConfigurator.fullScreenCollectionBehavior(behavior)

        // then
        #expect(!result.contains(.fullScreenNone))
        #expect(result.contains(.fullScreenPrimary))
    }

    @Test func givenUnrelatedFlags_whenApplied_thenTheySurvive() {
        // given
        let behavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .managed, .fullScreenAuxiliary]

        // when
        let result = MainWindowConfigurator.fullScreenCollectionBehavior(behavior)

        // then
        #expect(result.contains(.moveToActiveSpace))
        #expect(result.contains(.managed))
        #expect(result.contains(.fullScreenPrimary))
        #expect(!result.contains(.fullScreenAuxiliary))
    }

    @Test func givenTheResult_whenAppliedAgain_thenItIsANoOp() {
        // given
        let behavior: NSWindow.CollectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .fullScreenNone]
        let once = MainWindowConfigurator.fullScreenCollectionBehavior(behavior)

        // when
        let twice = MainWindowConfigurator.fullScreenCollectionBehavior(once)

        // then
        #expect(twice == once)
    }

    @MainActor
    @Test func givenAWindow_whenConfigured_thenItsTitleIsHiddenButStillSet() {
        // given
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        window.title = "Polybridge Monitor"

        // when
        MainWindowConfigurator.configure(window)

        // then
        #expect(window.titleVisibility == .hidden)
        #expect(window.title == "Polybridge Monitor")
        #expect(window.collectionBehavior.contains(.fullScreenPrimary))
    }
}
