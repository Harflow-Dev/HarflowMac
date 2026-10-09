//
//  SidebarVMTests+Conversation.swift
//  MainWindowFeatureTests
//
//  Monitor piece 7: a follow-up continues the same conversation. Split out of SidebarVMTests.swift
//  purely to keep that file/type under the swiftlint length budget — same harness, same suite.
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

    @Test func givenAResumedRootTask_whenListed_thenItIsOneRowNamedByTheFirstAndStatusedByTheCurrent() async {
        // given — "a" is resumed as "b"; before piece 7 these would be two separate recent rows.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a")
        ])

        // then
        await waitUntil { !sut.recentRows.isEmpty }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["a"], "one row, tagged by the conversation's first id")
        #expect(sut.recentRows.first?.title == "Task a", "the title comes from the first member")
    }

    @Test func givenAResumedTaskWhereTheFollowUpIsStillRunning_whenListed_thenItShowsInRunningWithTheCurrentsStatus() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "running", startedAt: .now, parentTaskID: "a")
        ])

        // then
        await waitUntil { !sut.runningRows.isEmpty }
        await sut.waitForPresentation()
        #expect(sut.runningRows.map(\.id) == ["a"])
        #expect(sut.runningRows.first?.status == .running, "status comes from the CURRENT member")
        #expect(sut.runningRows.first?.isRunning == true)
        #expect(sut.recentRows.isEmpty)
    }

    @Test func givenSelectionOnANonFirstMember_whenPublished_thenTheConversationsFirstRowHighlights() async {
        // given — Review round 1, item 5: selecting any member normalises to the conversation's row.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a")
        ])
        await waitUntil { !sut.recentRows.isEmpty }
        await sut.waitForPresentation()

        // when — the newest member ("b") is selected, e.g. via a URL or notification
        selectionSubject.send(.task("b"))

        // then — the row (tagged `.task("a")`) is what the sidebar's `List(selection:)` compares
        // against, so normalising to "a" is what makes the row actually highlight.
        await waitUntil { sut.selection == .task("a") }
        await sut.waitForPresentation()
        #expect(sut.selection == .task("a"))
    }

    @Test func givenARevealForANonFirstMember_whenApplied_thenItExpandsTheConversationsOwnAncestors() async {
        // given — "root" spawned "a", which was later resumed as "b"; revealing "b" (the newest
        // member) must expand "root" — the conversation(a,b)'s own ancestor — not try to expand
        // anything keyed by "b" itself (the row is tagged "a").
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let revealSubject = harness.revealSubject
        let routing = harness.routing
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "root", status: "completed"),
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100), spawnedBy: "root"),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a")
        ])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "root")
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root"])

        // when
        let reveal = PendingReveal(taskID: "b", requestID: UUID())
        revealSubject.send(reveal)

        // then
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["root", "a"])
        verify(routing).consumeReveal(requestID: .value(reveal.requestID)).called(1)
    }

    @Test func givenASubTaskSpawnedByTheFollowUp_whenListed_thenItAttachesUnderTheConversationsRow() async {
        // given — Design point 3: sub-tasks of ANY member hang under the conversation's own node.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()

        // when
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a"),
            task(id: "child", status: "completed", startedAt: .now.addingTimeInterval(50), spawnedBy: "b")
        ])

        // then
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["a", "child"])
        #expect(sut.recentRows.first?.hasChildren == true)
    }

    @Test func givenAConversationSelectedByAnOlderMember_whenLeftArrowIsPressed_thenItCollapsesTheRow() async {
        // given — keyboard collapse/expand key off the (already normalised) `selection`, so this is
        // mostly a regression guard that conversation ids and the collapse set agree.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a"),
            task(id: "child", status: "completed", startedAt: .now.addingTimeInterval(50), spawnedBy: "b")
        ])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        selectionSubject.send(.task("a"))
        await waitUntil { sut.selection == .task("a") }
        await sut.waitForPresentation()

        // when
        sut.didPressMoveCommand(.left)
        await sut.waitForPresentation()

        // then
        #expect(sut.recentRows.map(\.id) == ["a"])
        #expect(sut.recentRows.first?.isExpanded == false)
    }

    // MARK: - Retention while open (Review round 1, item 4)

    @Test func givenTheFirstMembersRecordIsPrunedByRetention_whenTheListingUpdates_thenTheSelectionMovesToTheSurvivingConversation() async {
        // given — "a" is selected (the conversation's first/identity id); "b" is its follow-up.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a")
        ])
        await waitUntil { !sut.recentRows.isEmpty }
        await sut.waitForPresentation()
        selectionSubject.send(.task("a"))
        await waitUntil { sut.selection == .task("a") }
        await sut.waitForPresentation()

        // when — retention prunes "a"'s own record; only "b" remains, which becomes its own new
        // conversation identity ("b") since its former parent is now missing from the listing.
        tasksSubject.send([task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a")])

        // then — the selection follows the conversation to its new identity, so the surviving row
        // still highlights (nothing new was ever selected — this happens on the recompute alone).
        await waitUntil { sut.recentRows.map(\.id) == ["b"] }
        await sut.waitForPresentation()
        #expect(sut.selection == .task("b"))
    }

    @Test func givenANestedConversationsFirstMemberIsPrunedByRetention_whenTheListingUpdates_thenSelectionAndCollapseBothHandOffToTheSurvivor() async {
        // given — conv(a,b) NESTS under "p" (a.spawnedBy == "p"), rather than being a top-level
        // section root; "child" hangs off the conversation's own current member ("b"). Codex review
        // round 1, finding 2: `recordMembership` must walk the WHOLE tree via `.flattened()` — not
        // just the top-level roots in `sections.running`/`sections.recent` — or this NESTED
        // conversation's membership (a ↔ b) is never remembered, and neither the selection nor the
        // collapse can hand off once "a" is pruned.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "p", status: "completed", startedAt: .now.addingTimeInterval(-200)),
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100), spawnedBy: "p"),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a"),
            task(id: "child", status: "completed", startedAt: .now.addingTimeInterval(50), spawnedBy: "b")
        ])
        // conv(a,b) NESTS under "p" (a.spawnedBy == "p"), so it is "p"'s own child row, not a
        // separate top-level entry sorted against it.
        await waitUntil { sut.recentRows.map(\.id) == ["p", "a", "child"] }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "a")
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["p", "a"], "collapsing conv(a,b) hides its own child")
        selectionSubject.send(.task("a"))
        await waitUntil { sut.selection == .task("a") }
        await sut.waitForPresentation()

        // when — retention prunes "a"; "b" becomes conv(a,b)'s new identity (and, losing "a"'s own
        // `spawned_by` link to "p", surfaces as its own top-level row rather than staying nested).
        tasksSubject.send([
            task(id: "p", status: "completed", startedAt: .now.addingTimeInterval(-200)),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a"),
            task(id: "child", status: "completed", startedAt: .now.addingTimeInterval(50), spawnedBy: "b")
        ])

        // then — the selection follows to the new id...
        await waitUntil { sut.selection == .task("b") }
        await sut.waitForPresentation()
        // ...and the collapse carried too: "b"'s own row is still collapsed, so "child" stays
        // hidden rather than reappearing because "b" was never itself collapsed.
        await waitUntil { sut.recentRows.map(\.id) == ["b", "p"] }
        await sut.waitForPresentation()
        #expect(sut.recentRows.first { $0.id == "b" }?.isExpanded == false)
    }

    @Test func givenACollapsedConversationsFirstMemberIsPrunedByRetention_whenTheListingUpdates_thenTheCollapseCarriesToTheNewID() async {
        // given — conversation(a,b) has a child ("child", spawned by "b"); "a" (its id) is collapsed
        // while it is still the conversation's identity.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a"),
            task(id: "child", status: "completed", startedAt: .now.addingTimeInterval(50), spawnedBy: "b")
        ])
        await waitUntil { sut.recentRows.count == 2 }
        await sut.waitForPresentation()
        sut.didToggleExpansion(taskID: "a")
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["a"])

        // when — retention prunes "a"; "b" becomes the conversation's new (singleton, for now) id.
        tasksSubject.send([
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a"),
            task(id: "child", status: "completed", startedAt: .now.addingTimeInterval(50), spawnedBy: "b")
        ])

        // then — the collapse carried across: "child" stays hidden under the NEW id "b", rather
        // than reappearing because "b" was never itself collapsed.
        await waitUntil { sut.recentRows.map(\.id) == ["b"] }
        await sut.waitForPresentation()
        #expect(sut.recentRows.first?.isExpanded == false)
    }

    @Test func givenBranchingFollowUpsAfterAPrune_whenTheListingUpdates_thenTheOldestSurvivingMemberBecomesTheNewIdentityDeterministically() async {
        // given — Codex review round 1, finding 3: "a" was resumed into BOTH "b" and "c" — a
        // branching conversation, {a, b, c} — and gets pruned by retention. The old implementation
        // picked a survivor with `Set.first`, which has no defined order; `Lineage.oldestSurvivor`
        // (the SAME deterministic rule `TaskDetailVM` uses via one shared helper) must always land
        // on "b" (`started_at` ascending), never "c", regardless of how the underlying set iterates.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "completed", startedAt: .now.addingTimeInterval(-50), parentTaskID: "a"),
            task(id: "c", status: "completed", startedAt: .now, parentTaskID: "a")
        ])
        await waitUntil { !sut.recentRows.isEmpty }
        await sut.waitForPresentation()
        selectionSubject.send(.task("a"))
        await waitUntil { sut.selection == .task("a") }
        await sut.waitForPresentation()

        // when — retention prunes "a"; "b" and "c" both survive as candidates, each now its own
        // singleton conversation (their shared link to "a" is gone with it).
        tasksSubject.send([
            task(id: "b", status: "completed", startedAt: .now.addingTimeInterval(-50), parentTaskID: "a"),
            task(id: "c", status: "completed", startedAt: .now, parentTaskID: "a")
        ])

        // then — the deterministic rule always resolves the stale selection to "b", never "c".
        await waitUntil { sut.selection == .task("b") }
        await sut.waitForPresentation()
        #expect(sut.selection == .task("b"))
    }

    @Test func givenAConversationHiddenBySearchAndPrunedWhileHidden_whenTheSearchClears_thenTheSurvivorIsSelected() async {
        // given — Codex review round 2, finding 3: "a" is selected, then a search query hides its
        // whole conversation from `sections.recent` entirely (`keep(tree)` fails for it). Its
        // follow-up "b" arrives, then retention prunes "a" — all while the conversation stays
        // hidden. Recording retention membership only from the FILTERED tree would never learn that
        // "a" and "b" belonged together, since neither one is ever in `sections` while the search
        // stays active.
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let selectionSubject = harness.selectionSubject
        sut.didAppear()
        await sut.waitForPresentation()
        tasksSubject.send([task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100))])
        await waitUntil { !sut.recentRows.isEmpty }
        await sut.waitForPresentation()
        selectionSubject.send(.task("a"))
        await waitUntil { sut.selection == .task("a") }
        await sut.waitForPresentation()

        // when — a search that matches neither "a" nor "b" hides the whole conversation.
        sut.didChangeSearchQuery("zzz-does-not-match-anything")
        await sut.waitForPresentation()
        await waitUntil { sut.recentRows.isEmpty }
        await sut.waitForPresentation()

        // "b" arrives as "a"'s follow-up, then "a" is pruned by retention — both while still
        // hidden by the search.
        tasksSubject.send([
            task(id: "a", status: "completed", startedAt: .now.addingTimeInterval(-100)),
            task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a")
        ])
        tasksSubject.send([task(id: "b", status: "completed", startedAt: .now, parentTaskID: "a")])

        // then — clearing the search reveals "b" as the survivor, and the stale selection on "a"
        // resolves to it, rather than staying stuck on "a" (which no longer identifies anything).
        sut.didChangeSearchQuery("")
        await sut.waitForPresentation()
        await waitUntil { sut.selection == .task("b") }
        await sut.waitForPresentation()
        #expect(sut.recentRows.map(\.id) == ["b"])
    }
}
