//
//  SidebarVMTests+Backends.swift
//  MainWindowFeatureTests
//
//  Monitor piece 6 (backend tabs + filter-aware empty states): split out of SidebarVMTests.swift
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

    // MARK: - Backend tabs (Monitor piece 6)

    func catalog(_ entries: [(String, Bool?)], state: BackendCatalogState = .available) -> BackendCatalog {
        BackendCatalog(entries: entries.map { BackendCatalogEntry(backend: $0.0, installed: $0.1) }, state: state)
    }

    @Test func givenEqualUsage_whenComputed_thenTiesKeepRegistryOrderThenAlphabeticalHistoryOnly() async {
        // given — "All" first, then most-used; equal counts keep registry order from the catalog,
        // then history-only names alphabetically, and an unused backend comes last.
        let harness = makeSUT(catalog: catalog([("claude", true), ("codex", false)]))
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()

        // when
        tasksSubject.send([
            task(id: "t1", backend: "claude", status: "completed"),
            task(id: "t2", backend: "zeta", status: "completed"),
            task(id: "t3", backend: "alpha", status: "completed")
        ])

        // then
        await waitUntil { sut.backendTabs.count == 5 }
        #expect(sut.backendTabs.map(\.id) == ["all", "claude", "alpha", "zeta", "codex"])
    }

    @Test func givenDifferentUsage_whenComputed_thenTabsAreOrderedByMostUsed() async {
        // given
        let harness = makeSUT(catalog: catalog([("claude", true), ("codex", true), ("opencode", true), ("vibe", true)]))
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        sut.didAppear()

        // when — vibe 3, codex 2, claude 1, opencode 0
        tasksSubject.send([
            task(id: "v1", backend: "vibe", status: "completed"),
            task(id: "v2", backend: "vibe", status: "completed"),
            task(id: "v3", backend: "vibe", status: "completed"),
            task(id: "x1", backend: "codex", status: "completed"),
            task(id: "x2", backend: "codex", status: "completed"),
            task(id: "c1", backend: "claude", status: "completed")
        ])

        // then
        await waitUntil { sut.backendTabs.map(\.id).dropFirst().first == "vibe" }
        #expect(sut.backendTabs.map(\.id) == ["all", "vibe", "codex", "claude", "opencode"])
    }

    @Test func givenABackendReportedNotInstalled_whenTabsComputed_thenItIsMarkedNotFound() async {
        // given
        let harness = makeSUT(catalog: catalog([("claude", true), ("codex", false)]))
        let sut = harness.sut
        sut.didAppear()

        // then
        await waitUntil { sut.backendTabs.count == 3 }
        #expect(sut.backendTabs.first { $0.id == "claude" }?.isNotFound == false)
        #expect(sut.backendTabs.first { $0.id == "codex" }?.isNotFound == true)
    }

    @Test func givenADegradedCatalogWithNoEntries_whenComputed_thenOnlyAllShowsWithTheUnavailableNote() async {
        // given
        let harness = makeSUT(catalog: BackendCatalog(entries: [], state: .degraded))
        let sut = harness.sut
        sut.didAppear()

        // then
        await waitUntil { sut.catalogUnavailableNote != nil }
        #expect(sut.backendTabs.map(\.id) == ["all"])
        #expect(sut.catalogUnavailableNote == "Backend list unavailable — update polybridge.")
    }

    @Test func givenASelectedBackendThatVanishesFromCatalogAndHistory_whenRecomputed_thenSelectionFallsBackToAll() async {
        // given
        let harness = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let catalogSubject = harness.catalogSubject
        let catalogBox = harness.catalogBox
        sut.didAppear()
        tasksSubject.send([task(id: "t1", backend: "codex", status: "completed")])
        await waitUntil { sut.backendTabs.count == 2 }
        sut.didSelectBackendFilter("codex")
        #expect(sut.selectedBackend == "codex")

        // when — codex disappears from both the catalog and history.
        catalogBox.value = catalog([("claude", true)])
        catalogSubject.send(catalogBox.value)
        tasksSubject.send([])

        // then
        await waitUntil { sut.selectedBackend == "all" }
        #expect(sut.selectedBackend == "all")
    }

    // MARK: - Empty-state precedence (Monitor piece 6, Review round 1 item 3)

    @Test func givenAnInstalledBackendSelectedWithNoTasks_whenComputed_thenTheCopyNamesTheBackend() async {
        // given
        let harness = makeSUT(catalog: catalog([("claude", true)]))
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        hasListedSubject.send(true)
        await waitUntil { sut.backendTabs.count == 2 }

        // when
        sut.didSelectBackendFilter("claude")
        tasksSubject.send([])

        // then
        await waitUntil { sut.emptyStateMessage != nil }
        #expect(sut.emptyStateMessage == "No claude tasks yet.")
    }

    @Test func givenANotInstalledBackendSelectedWithNoTasks_whenComputed_thenTheCopySaysItWasNotFound() async {
        // given
        let harness = makeSUT(catalog: catalog([("codex", false)]))
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        hasListedSubject.send(true)
        await waitUntil { sut.backendTabs.count == 2 }

        // when
        sut.didSelectBackendFilter("codex")
        tasksSubject.send([])

        // then
        await waitUntil { sut.emptyStateMessage != nil }
        #expect(sut.emptyStateMessage == "codex wasn't found on your PATH — install its CLI to run codex tasks.")
    }

    @Test func givenADegradedCatalogWithACarriedOverBackendSelected_whenNoTasksMatch_thenTheCopyTreatsItAsUnknownNotMissing() async {
        // given — Review round 1 item 2: "install status unknown (older ctl) → 'No <backend> tasks
        // yet.'" — never the "wasn't found" copy, which would be a false claim about a backend the
        // catalog simply couldn't confirm either way.
        let harness = makeSUT(catalog: BackendCatalog(entries: [BackendCatalogEntry(backend: "claude", installed: nil)], state: .degraded))
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        hasListedSubject.send(true)
        await waitUntil { sut.backendTabs.count == 2 }

        // when
        sut.didSelectBackendFilter("claude")
        tasksSubject.send([])

        // then
        await waitUntil { sut.emptyStateMessage != nil }
        #expect(sut.emptyStateMessage == "No claude tasks yet.")
    }

    @Test func givenANonBlankSearchWithNoMatches_whenComputed_thenItOutranksTheBackendCopy() async {
        // given — search precedence beats the backend-specific message even while a backend is
        // selected (Design point 4's "takes precedence over the above").
        let harness = makeSUT(catalog: catalog([("codex", false)]))
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        hasListedSubject.send(true)
        sut.didSelectBackendFilter("codex")
        tasksSubject.send([])
        await waitUntil { sut.emptyStateMessage != nil }

        // when
        sut.didChangeSearchQuery("hello")

        // then
        #expect(sut.emptyStateMessage == "No tasks match \"hello\".")
    }

    @Test func givenAWhitespaceOnlySearch_whenComputed_thenItCountsAsNoSearch() async {
        // given
        let harness = makeSUT(catalog: catalog([("claude", true)]))
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        hasListedSubject.send(true)
        tasksSubject.send([])
        await waitUntil { sut.emptyStateMessage != nil }

        // when
        sut.didChangeSearchQuery("   ")

        // then — falls through to the "All" copy, not a search-shaped one.
        #expect(sut.emptyStateMessage == "No tasks yet. Tasks started through polybridge appear here.")
    }

    @Test func givenOnlyAParallelGroupMatches_whenComputed_thenTheEmptyMessageIsSuppressed() async {
        // given — a parallel-only match must suppress the empty message exactly like running/recent
        // rows do (Review round 1 item 3's "if any filtered content exists").
        let harness = makeSUT()
        let sut = harness.sut
        let tasksSubject = harness.tasksSubject
        let hasListedSubject = harness.hasListedSubject
        sut.didAppear()
        hasListedSubject.send(true)

        // when — two tasks sharing a group, neither running, form a parallel group with no
        // running/recent rows of their own once grouped.
        tasksSubject.send([
            task(id: "g1", status: "completed", group: "release"),
            task(id: "g2", status: "completed", group: "release")
        ])

        // then
        await waitUntil { !sut.parallelGroups.isEmpty }
        #expect(sut.emptyStateMessage == nil)
    }
}
