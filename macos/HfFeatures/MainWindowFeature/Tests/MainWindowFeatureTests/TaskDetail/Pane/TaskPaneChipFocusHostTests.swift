//
//  TaskPaneChipFocusHostTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

// MARK: - TaskPaneChipFocusHostTests

/// The live host's lifecycle with no window: probing only reads, a started return owns the input watch, and a disappearance
/// removes it and assigns nothing.
@MainActor
struct TaskPaneChipFocusHostTests {
    @Test func givenAHostWithNoWindow_whenProbed_thenFocusIsNotInThePaneAndNothingIsWatched() {
        // given
        let host = TaskPaneChipFocusHost()
        defer { host.cancel() }

        // when
        let snapshot = host.probe()

        // then probing only reads: a close that never starts a native return (a header origin) leaves nothing running
        #expect(!snapshot.worthReturning && snapshot.window == nil)
        #expect(!host.isWatchingInput)
    }

    @Test func givenAStartedReturnThatIsSkipped_whenItFinishes_thenTheInputWatchIsRemoved() async {
        // given
        let host = TaskPaneChipFocusHost()
        defer { host.cancel() }
        var applied = 0

        // when
        host.start(identifier: "task-detail.chip.notices", snapshot: host.probe(), isCurrent: { true }, applyBindings: { applied += 1 })
        #expect(host.isWatchingInput, "the watch begins with the native return, not with the probe")
        await waitUntil { host.lastOutcome != nil }

        // then
        #expect(host.lastOutcome == .skipped(.notInPane))
        #expect(!host.isWatchingInput && applied == 0)
    }

    @Test func givenAStartedReturn_whenTheViewDisappears_thenTheWatchIsRemovedAndNoBindingIsAssigned() async {
        // given
        let host = TaskPaneChipFocusHost()
        var applied = 0
        let inPane = PaneFocusSnapshot(axFocusInPane: true, nativeFocusInDetail: false, window: nil)
        host.start(identifier: "task-detail.chip.notices", snapshot: inPane, isCurrent: { true }, applyBindings: { applied += 1 })
        #expect(host.isWatchingInput)

        // when
        host.cancel()
        for _ in 0 ..< 5 { await Task.yield() }

        // then
        #expect(!host.isWatchingInput && applied == 0)
    }
}
