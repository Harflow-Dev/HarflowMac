//
//  TaskPaneControllerFocusReturnTests.swift
//  MainWindowFeatureTests
//

import AppKit
@testable import MainWindowFeature
import Testing

// MARK: - TaskPaneControllerFocusReturnTests

/// What the controller records for a native focus return: the close-time focus snapshot and the generation that makes a
/// deferred return stale.
@MainActor
struct TaskPaneControllerFocusReturnTests {

    private func make() -> TaskPaneController {
        let sut = TaskPaneController(store: TaskPaneStateStore(), conversationID: "conv")
        sut.updateContainerWidth(1280)
        return sut
    }

    @Test func givenARevealedPane_whenClosed_thenTheProbeIsReadBeforeTheCloseAndHandedOverOnce() {
        // given
        let sut = make()
        var probed = 0
        var openAtProbe: Bool?
        sut.focusProbe = { [unowned sut] in
            probed += 1
            openAtProbe = sut.isOpen
            return PaneFocusSnapshot(axFocusInPane: true, nativeFocusInDetail: false, window: nil)
        }
        sut.revealFacts(group: .notices, origin: .chipNotices)

        // when
        sut.close()

        // then the focus was read while the pane was still open
        #expect(probed == 1 && openAtProbe == true)
        #expect(sut.focusReturn == .chipNotices)
        #expect(sut.takeReturnSnapshot()?.axFocusInPane == true)
        #expect(sut.takeReturnSnapshot() == nil, "a snapshot is handed over once")
    }

    @Test func givenAPaneThePersonOpened_whenClosed_thenNoFocusIsProbedAndNoReturnIsRequested() {
        // given
        let sut = make()
        var probed = 0
        sut.focusProbe = { probed += 1; return PaneFocusSnapshot(axFocusInPane: true, nativeFocusInDetail: false, window: nil) }
        sut.open()

        // when
        sut.close()

        // then
        #expect(probed == 0 && sut.focusReturn == nil && sut.takeReturnSnapshot() == nil)
    }

    @Test func givenARevealedCloseWithoutAMountedView_whenClosed_thenTheReturnStillRunsThroughTheSwiftUIPath() {
        // given no probe, as in a controller with no mounted view
        let sut = make()
        sut.revealFacts(group: .continuity, origin: .chipContinuity)

        // when
        sut.close()

        // then
        #expect(sut.focusReturn == .chipContinuity && sut.takeReturnSnapshot() == nil)
    }

    @Test func givenAClose_whenTheLaterPaneChangesHappen_thenTheEarlierReturnIsNoLongerCurrent() {
        // given
        let sut = make()
        sut.revealFacts(group: .notices, origin: .chipNotices)
        sut.close()
        let generation = sut.returnGeneration
        #expect(sut.isCurrentReturn(generation: generation), "a closed pane with no later change is current")

        // when / then each later change makes it stale
        sut.open()
        #expect(!sut.isCurrentReturn(generation: generation), "a reopen")

        sut.close()
        let second = sut.returnGeneration
        #expect(sut.isCurrentReturn(generation: second))
        sut.revealFacts(group: .continuity, origin: .chipContinuity)
        #expect(!sut.isCurrentReturn(generation: second), "a new reveal")

        sut.close()
        let third = sut.returnGeneration
        sut.select(.artifacts)
        #expect(!sut.isCurrentReturn(generation: third), "a tab choice")
    }

    @Test func givenAnOpenPane_whenAskedIfAReturnIsCurrent_thenItIsNot() {
        // given
        let sut = make()
        sut.revealFacts(group: .notices, origin: .chipNotices)

        // then a return is only ever for a closed pane
        #expect(!sut.isCurrentReturn(generation: sut.returnGeneration))
    }

    @Test func givenTwoClosesInARow_whenTheSecondArrives_thenTheFirstReturnIsStale() {
        // given
        let sut = make()
        sut.revealFacts(group: .notices, origin: .chipNotices)
        sut.close()
        let first = sut.returnGeneration

        // when
        sut.revealFacts(group: .notices, origin: .chipNotices)
        sut.close()

        // then
        #expect(!sut.isCurrentReturn(generation: first))
        #expect(sut.isCurrentReturn(generation: sut.returnGeneration))
    }
}
