//
//  SidebarVMTests+Tree.swift
//  MainWindowFeatureTests
//
//  Monitor piece 4 (collapsible task tree): split out of SidebarVMTests.swift purely to keep
//  that file/type under the swiftlint length budget — same harness, same suite.
//

import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import SwiftUI
import Testing

@MainActor
extension SidebarVMTests {

    // MARK: - Collapsible tree (settled plan, Design points 1-4)

    @Test func givenARootWithAChild_whenListed_thenItIsExpandedByDefault() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])

        // then
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
        let rootRow = sut.recentRows.first { $0.id == "root" }
        #expect(rootRow?.hasChildren == true)
        #expect(rootRow?.isExpanded == true)
    }

    @Test func givenAnExpandedParent_whenToggled_thenOnlyItsDescendantsHideAndTheSummaryReplacesTheMetaLine() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()

        // when
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()

        // then — the parent's own row stays, only the descendant hides
        #expect(sut.recentRows.map(\.id) == ["root"])
        #expect(sut.recentRows.first?.isExpanded == false)
        #expect(sut.recentRows.first?.subTaskSummary == "1 sub-task")

        // when — toggled back
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
        #expect(sut.recentRows.first?.isExpanded == true)
    }

    @Test func givenACollapsedParentWithARunningDescendant_whenSummarized_thenTheRunningCountShows() async {
        // given — "3 sub-tasks, 1 running" (settled plan, Design point 4). A running descendant
        // keeps the whole tree in `runningRows` (Lineage's own "whole tree" rule).
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "root", status: "completed"),
            task(id: "c1", status: "running", spawnedBy: "root"),
            task(id: "c2", status: "completed", spawnedBy: "root"),
            task(id: "c3", status: "completed", spawnedBy: "c2")
        ])
        await waitUntil { sut.runningRows.count == 4 }
        await sut.waitForPresentation()

        // when
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()

        // then
        #expect(sut.runningRows.map(\.id) == ["root"])
        #expect(sut.runningRows.first?.subTaskSummary == "3 sub-tasks, 1 running")
    }

    @Test func givenACollapsedParentWithNoRunningDescendants_whenSummarized_thenTheRunningCountIsOmitted() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "root", status: "completed"),
            task(id: "c1", status: "completed", spawnedBy: "root"),
            task(id: "c2", status: "completed", spawnedBy: "root")
        ])
        await waitUntil { sut.recentRows.count == 3 }
        await sut.waitForPresentation()

        // when
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.first?.subTaskSummary == "2 sub-tasks")
    }

    @Test func givenASelectedTask_whenTogglingAnUnrelatedExpansion_thenTheSelectionIsUnchanged() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        selectionSubject.send(.task("root"))
        await waitUntil { sut.selection == .task("root") }
        await sut.waitForPresentation()

        // when
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()

        // then
        #expect(sut.selection == .task("root"))
    }

    @Test func givenTheSelectedTasksParentIsCollapsed_whenRecomputed_thenTheSelectionStaysOnTheHiddenTask() async {
        // given — collapsing a row must never clear a selection it hides; only the displayed rows
        // change (Design point 5's "Navigation reveals, recompute doesn't" rule).
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        selectionSubject.send(.task("child"))
        await waitUntil { sut.selection == .task("child") }
        await sut.waitForPresentation()

        // when
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.map(\.id) == ["root"])
        #expect(sut.selection == .task("child"))
    }

    @Test func givenACollapsedTask_whenDisappearingAndReappearing_thenTheCollapseStateSurvives() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])

        // when
        sut.didDisappear()
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])

        // then
        await waitUntil { sut.recentRows.count == 1 }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])
    }

    // MARK: - Filter forces display expansion only (Design point 5's "Filter" rule)

    @Test func givenAMatchingGrandchildUnderACollapsedParent_whenFiltering_thenItsAncestorsDisplayExpanded() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let titlesBox = harness.titlesBox
        titlesBox.value = ["root": "Root task", "child": "Child task", "grandchild": "Fix the login bug"]
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root"),
            task(id: "grandchild", status: "completed", spawnedBy: "child")
        ])
        await waitUntil { sut.recentRows.count == 3 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])

        // when
        sut.didChangeSearchQuery("login")
        await sut.waitForPresentation()

        // then — the match's ancestors display expanded, without touching the collapsed set
        #expect(sut.recentRows.map(\.id) == ["root", "child", "grandchild"])

        // when — clearing the filter
        sut.didChangeSearchQuery("")
        await sut.waitForPresentation()

        // then — the person's own collapse is restored exactly
        #expect(sut.recentRows.map(\.id) == ["root"])
    }

    // MARK: - Navigation reveal (settled plan, Design point 5's coordinator-owned pending reveal)

    @Test func givenAHiddenDescendant_whenRevealed_thenItsAncestorsExpandAndTheRevealIsConsumed() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let revealSubject = harness.revealSubject
        let routing = harness.routing
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])

        // when
        let reveal = PendingReveal(taskID: "child", requestID: UUID())
        revealSubject.send(reveal)

        // then
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
        verify(routing).consumeReveal(requestID: .value(reveal.requestID)).called(1)
    }

    @Test func givenARepeatedNavigationToTheSameHiddenTaskAfterReCollapsing_whenRevealed_thenItRevealsAgain() async {
        // given — `selection`'s own `didSet` would drop a repeated assignment; the reveal channel
        // must not (a fresh `requestID` every time).
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let revealSubject = harness.revealSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        revealSubject.send(PendingReveal(taskID: "child", requestID: UUID()))
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root") // the person re-collapses it, deliberately
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])

        // when — navigating again to the same hidden task
        revealSubject.send(PendingReveal(taskID: "child", requestID: UUID()))

        // then
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
    }

    @Test func givenARevealForATaskNotYetListed_whenDataArrives_thenItAppliesAndConsumesThen() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let revealSubject = harness.revealSubject
        let routing = harness.routing
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])

        // when — the reveal targets a grandchild that isn't listed yet
        let reveal = PendingReveal(taskID: "grandchild", requestID: UUID())
        revealSubject.send(reveal)

        // then — stays pending, nothing consumed or expanded. `revealSubject` hops through
        // `.receive(on: DispatchQueue.main)`, so poll for the wrong outcome with a bounded timeout
        // (as `givenDidDisappearThenDidAppearAgain…` does) rather than asserting synchronously,
        // which would pass trivially before the hop has even run.
        await waitUntil(timeout: 0.3) { sut.recentRows.count != 1 }
        #expect(sut.recentRows.map(\.id) == ["root"])
        verify(routing).consumeReveal(requestID: .any).called(0)

        // when — the listing now includes it
        tasksSubject.send([
            task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root"),
            task(id: "grandchild", status: "completed", spawnedBy: "child")
        ])

        // then
        await waitUntil { sut.recentRows.count == 3 }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root", "child", "grandchild"])
        verify(routing).consumeReveal(requestID: .value(reveal.requestID)).called(1)
    }

    @Test func givenAUserCollapse_whenAnOrdinaryListingUpdateArrives_thenItStaysCollapsed() async {
        // given — an ordinary recompute (a new listing, unrelated to any reveal) must never
        // re-expand a row the person collapsed.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()
        let earlier = Date.now.addingTimeInterval(-100)
        tasksSubject.send([
            task(id: "root", status: "completed", startedAt: earlier),
            task(id: "child", status: "completed", startedAt: earlier, spawnedBy: "root")
        ])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])

        // when — an unrelated task joins the listing
        tasksSubject.send([
            task(id: "root", status: "completed", startedAt: earlier), task(id: "child", status: "completed", startedAt: earlier, spawnedBy: "root"),
            task(id: "other", status: "completed")
        ])

        // then — "other" started later, so it sorts first; "root" stays collapsed
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["other", "root"])
    }

    @Test func givenARevealWhileTheSidebarIsClosed_whenReappearing_thenItIsAppliedFromTheCoordinatorsPendingReveal() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let routing = harness.routing
        let pendingRevealBox = harness.pendingRevealBox
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        sut.didDisappear()

        // when — a reveal arrives while unsubscribed; the coordinator still records it
        let reveal = PendingReveal(taskID: "child", requestID: UUID())
        pendingRevealBox.value = reveal
        sut.didAppear()
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
        verify(routing).consumeReveal(requestID: .value(reveal.requestID)).called(1)
    }

    @Test func givenTheSameHiddenTaskNavigatedToTwiceWhileClosed_whenReappearingEachTime_thenItRevealsBothTimes() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let pendingRevealBox = harness.pendingRevealBox
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        sut.didDisappear()
        pendingRevealBox.value = PendingReveal(taskID: "child", requestID: UUID())
        sut.didAppear()
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
        sut.didToggleExpansion(taskID: "root") // re-collapse, a deliberate user action
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])
        sut.didDisappear()

        // when — navigated to again while closed, a fresh requestID
        pendingRevealBox.value = PendingReveal(taskID: "child", requestID: UUID())
        sut.didAppear()
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
    }

    @Test func givenAnAlreadyConsumedReveal_whenAppearingAgainWithNoFreshOne_thenItDoesNotReExpand() async {
        // given — each reveal is consumed exactly once: once the coordinator has cleared it (no new
        // navigation happened), reappearing must not re-apply the stale value.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let pendingRevealBox = harness.pendingRevealBox
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        sut.didDisappear()
        pendingRevealBox.value = PendingReveal(taskID: "child", requestID: UUID())
        sut.didAppear()
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
        sut.didToggleExpansion(taskID: "root") // re-collapse, a deliberate user action
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])
        pendingRevealBox.value = nil // the coordinator has cleared it; no new navigation happened
        sut.didDisappear()

        // when
        sut.didAppear()
        await sut.waitForPresentation()

        // then — stays collapsed
        #expect(sut.recentRows.map(\.id) == ["root"])
    }

    // MARK: - Keyboard (Design point 2a)

    @Test func givenAnExpandedSelectedParent_whenLeftArrowIsPressed_thenItCollapsesWithoutMovingSelection() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        let routing = harness.routing
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        selectionSubject.send(.task("root"))
        await waitUntil { sut.selection == .task("root") }
        await sut.waitForPresentation()

        // when
        sut.didPressMoveCommand(.left)
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.map(\.id) == ["root"])
        verify(routing).select(.any).called(0)
    }

    @Test func givenALeafSelectedRow_whenLeftArrowIsPressed_thenSelectionMovesToItsParent() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        let routing = harness.routing
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        selectionSubject.send(.task("child"))
        await waitUntil { sut.selection == .task("child") }
        await sut.waitForPresentation()

        // when — "child" is a leaf
        sut.didPressMoveCommand(.left)
        await sut.waitForPresentation()

        // then
        verify(routing).select(.value(.task("root"))).called(1)
    }

    @Test func givenAnAlreadyCollapsedSelectedParent_whenLeftArrowIsPressed_thenSelectionMovesToItsParent() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        let routing = harness.routing
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "root", status: "completed"), task(id: "mid", status: "completed", spawnedBy: "root"),
            task(id: "leaf", status: "completed", spawnedBy: "mid")
        ])
        await waitUntil { sut.recentRows.count == 3 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "mid")
        await sut.waitForPresentation()
        selectionSubject.send(.task("mid"))
        await waitUntil { sut.selection == .task("mid") }
        await sut.waitForPresentation()

        // when — "mid" is already collapsed
        sut.didPressMoveCommand(.left)
        await sut.waitForPresentation()

        // then — moves to its parent instead of trying to collapse it again
        verify(routing).select(.value(.task("root"))).called(1)
    }

    @Test func givenACollapsedSelectedParent_whenRightArrowIsPressed_thenItExpands() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        selectionSubject.send(.task("root"))
        await waitUntil { sut.selection == .task("root") }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])

        // when
        sut.didPressMoveCommand(.right)
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
    }

    @Test func givenUpOrDownArrow_whenPressed_thenSelectionAndTreeStateAreUnaffected() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        let routing = harness.routing
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "root", status: "completed"), task(id: "child", status: "completed", spawnedBy: "root")])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        selectionSubject.send(.task("root"))
        await waitUntil { sut.selection == .task("root") }
        await sut.waitForPresentation()

        // when
        sut.didPressMoveCommand(.up)
        await sut.waitForPresentation()
        sut.didPressMoveCommand(.down)
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.map(\.id) == ["root", "child"])
        #expect(sut.selection == .task("root"))
        verify(routing).select(.any).called(0)
    }
}
