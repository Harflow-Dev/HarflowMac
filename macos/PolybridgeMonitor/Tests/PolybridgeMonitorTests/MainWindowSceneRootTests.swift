//
//  MainWindowSceneRootTests.swift
//  PolybridgeMonitorTests
//
//  Decision 3: the scene-root adapter registers the window opener on its own, with no menu-bar label
//  anywhere in the hierarchy. The adapter is hosted for real so its `onAppear` runs. What the
//  registered closure opens (`openWindow(id: "main")`) can't be observed here — `OpenWindowAction`
//  has no public initializer to fake — so that part stays with the manual reopen check.
//

import AppKit
import PbCommon
import PbTestUtilities
@testable import PolybridgeMonitor
import SwiftUI
import Testing

@MainActor
@Suite struct MainWindowSceneRootTests {

    @Test func givenTheSceneRootIsHostedWithoutAMenuBarLabel_whenItAppears_thenItRegistersAWindowOpener() async {
        // given
        let presenter = RecordingWindowPresenter()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: false)

        // when
        window.contentView = NSHostingView(rootView: MainWindowSceneRoot(windowPresenting: presenter) { Text("content") })
        window.contentView?.layoutSubtreeIfNeeded()
        await waitUntil { presenter.registrationCount > 0 }

        // then
        #expect(presenter.registrationCount == 1)
    }
}

// MARK: - RecordingWindowPresenter

private final class RecordingWindowPresenter: WindowPresenting {
    private(set) var registrationCount = 0

    func registerWindowOpener(_ opener: @escaping () -> Void) {
        registrationCount += 1
    }
}
