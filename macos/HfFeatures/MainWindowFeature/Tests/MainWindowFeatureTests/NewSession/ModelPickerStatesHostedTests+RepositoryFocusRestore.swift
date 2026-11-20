//
//  ModelPickerStatesHostedTests+RepositoryFocusRestore.swift
//  MainWindowFeatureTests
//

import AppKit
import Foundation
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import SwiftUI
import Testing

// MARK: - ModelPickerStatesHostedTests + Repository focus restore

/// A composer lock disables the native field and discards its editor. Unlocking gives focus back only when the field
/// held it at the lock, and only while nothing else has moved focus or the selection since. Every stimulus is real
/// AppKit input or the observer view model; cases that must interleave an unlock with another change use layout passes
/// to separate the SwiftUI updates, which is best effort because the restore itself runs on the next main-actor turn.
extension ModelPickerStatesHostedTests {

    @MainActor
    private struct FocusRestoreHost {
        let model: NewSessionVM
        let useCase: HostedListingUseCase
        let routing: MockNewSessionRouting
        let observed: RepositoryBindingObservedViewModel
        let fixture: Fixture
        let popover: NSWindow
        let field: NSTextField
        let editor: NSTextView
        let selectedBeforeLock: NSRange

        func dispose() {
            fixture.dispose()
            withExtendedLifetime(routing) {}
        }
    }

    private static let focusRestoreEdited = "/fixture/repos/pending-before-lock"

    private func openFocusRestoreHost(removableRoot: ComposerRootFlag? = nil) async throws -> FocusRestoreHost {
        let (model, useCase, routing) = makeRepositoryModel(repo: "/fixture/repos/initial", refusesStart: true)
        let observed = RepositoryBindingObservedViewModel(model)
        let fixture = removableRoot.map { makeRemovableFixture(observed, flag: $0) }
            ?? makeFixture(observed, size: NSSize(width: 1280, height: 800), dark: false,
                           harnessPresented: false, repositoryPresented: true)
        do {
            try await activate(fixture.window)
            try await requireEventually("the repository popover") { !ownedPopovers(of: fixture.window).isEmpty }
            let popover = try #require(ownedPopovers(of: fixture.window).first)
            let field = try #require(repositoryNativeField(in: popover))
            try #require(popover.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            let edited = Self.focusRestoreEdited
            editor.insertText(edited, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
            try await requireEventually("the edit to qualify") { model.repo.utf8.elementsEqual(edited.utf8) && model.canStart }
            editor.selectedRange = NSRange(location: 4, length: 3)
            try #require(popover.firstResponder === editor && field.currentEditor() === editor)
            return FocusRestoreHost(model: model, useCase: useCase, routing: routing, observed: observed, fixture: fixture,
                                    popover: popover, field: field, editor: editor, selectedBeforeLock: editor.selectedRange)
        } catch {
            fixture.dispose()
            withExtendedLifetime(routing) {}
            throw error
        }
    }

    private static let focusRestoreTransitionPath = "model call, then layoutSubtreeIfNeeded + displayIfNeeded on host, window and popover"

    /// The native control must have followed the model before the caller suspends, so a restore that already ran, or a
    /// transition SwiftUI coalesced away, cannot make a later assertion pass by accident.
    private func requireSynchronousTransition(_ host: FocusRestoreHost, enabled: Bool) throws {
        renderFocusRestoreHost(host)
        try #require(host.field.isEnabled == enabled,
                     Comment(rawValue: "The field did not become \(enabled ? "enabled" : "disabled") synchronously via \(Self.focusRestoreTransitionPath)."))
    }

    private func lockFocusRestoreHost(_ host: FocusRestoreHost) async throws {
        try await requireEventually("Start to qualify") { host.model.canStart }
        host.model.didTapStart()
        try requireSynchronousTransition(host, enabled: false)
        try await requireEventually("the refusal") { host.model.composerState == .refused }
        try await requireEventually("the native field to lock") { host.model.optionsLocked && !host.field.isEnabled }
    }

    private func unlockFocusRestoreHost(_ host: FocusRestoreHost) async throws {
        host.model.didTapReviewSettings()
        try requireSynchronousTransition(host, enabled: true)
        try await requireEventually("the native field to unlock") { !host.model.optionsLocked && host.field.isEnabled }
    }

    private func renderFocusRestoreHost(_ host: FocusRestoreHost) {
        host.fixture.host.layoutSubtreeIfNeeded()
        host.fixture.window.displayIfNeeded()
        host.popover.displayIfNeeded()
    }

    /// Gives a restore every chance to run, so a case asserting that none happened does not pass by being early.
    private func settleFocusRestore() async {
        for _ in 0 ..< 3 {
            await Task.yield()
            await DisplayFrames.waitForPresentedFrame()
        }
    }

    private func awaitRestoredEditor(_ host: FocusRestoreHost) async throws -> NSTextView {
        try await requireEventually("native focus to be restored") {
            host.field.currentEditor() != nil && host.popover.firstResponder === host.field.currentEditor()
        }
        return try #require(host.field.currentEditor() as? NSTextView)
    }

    private func expectNoRestore(_ host: FocusRestoreHost, writesBefore: [String], _ context: String) {
        let receipt = Comment(rawValue: "\(context) events=\(host.observed.events) firstResponder=\(String(describing: host.popover.firstResponder))")
        #expect(host.field.currentEditor() == nil, receipt)
        #expect(host.observed.repositoryWrites == writesBefore, receipt)
        #expect(!host.observed.events.contains { $0.hasPrefix("commit:") }, receipt)
        #expect(host.useCase.directoryChecks.isEmpty, receipt)
    }

    // MARK: Return after restore

    @Test
    func givenFocusWasRestoredAfterUnlock_whenReturnIsPressedWithoutTyping_thenNothingIsWrittenOrChecked() async throws {
        // given
        let started = Date()
        let host = try await openFocusRestoreHost()
        defer { host.dispose() }
        try await lockFocusRestoreHost(host)
        try await unlockFocusRestoreHost(host)
        let live = try await awaitRestoredEditor(host)
        #expect(live.selectedRange == host.selectedBeforeLock)
        let writesBefore = host.observed.repositoryWrites
        let eventsBefore = host.observed.events.count
        let ended = countEndEditing(of: host.field)
        defer { NotificationCenter.default.removeObserver(ended) }
        let selectedBeforeReturn = live.selectedRange

        // when
        try sendRepositoryProbeKey("\r", code: 36, to: host.popover)
        await settleFocusRestore()

        // then
        let receipt = Comment(rawValue: "events=\(host.observed.events) endEditing=\(ended.count)")
        #expect(ended.count <= 0, "Return must be handled by the field, not fall through to end editing. \(receipt)")
        #expect(host.field.currentEditor() === live && host.popover.firstResponder === live,
                "The restored editor must stay current and first responder. \(receipt)")
        #expect(live.selectedRange == selectedBeforeReturn, receipt)
        #expect(host.observed.repositoryWrites == writesBefore, receipt)
        #expect(!host.observed.events[eventsBefore...].contains { $0.hasPrefix("commit:") || $0.hasPrefix("write:") }, receipt)
        #expect(host.useCase.directoryChecks.isEmpty, receipt)
        try expectNoStateModificationWarning(since: started)
    }

    // MARK: Negative cases

    @Test
    func givenTheSelectionChangesAtUnlock_whenTheComposerUnlocks_thenFocusIsNotRestored() async throws {
        // given
        let started = Date()
        let host = try await openFocusRestoreHost()
        defer { host.dispose() }
        try await lockFocusRestoreHost(host)
        let writesBefore = host.observed.repositoryWrites
        let selected = "/fixture/repos/selected-during-unlock"

        // when
        let generationBefore = host.model.repoSelectionGeneration
        host.model.didTapReviewSettings()
        try requireSynchronousTransition(host, enabled: true)
        host.model.didTapRecentRepo(selected)
        try #require(host.model.repoSelectionGeneration == generationBefore + 1, "The selection must have changed before the restore can run.")
        renderFocusRestoreHost(host)
        await settleFocusRestore()

        // then
        #expect(host.model.repo.utf8.elementsEqual(selected.utf8))
        expectNoRestore(host, writesBefore: writesBefore, "selection change")
        try expectNoStateModificationWarning(since: started)
    }

    @Test
    func givenTheComposerDisappearsAfterUnlock_whenTheRestoreWouldRun_thenNothingIsRestoredWrittenOrChecked() async throws {
        // given
        let started = Date()
        let flag = ComposerRootFlag()
        let host = try await openFocusRestoreHost(removableRoot: flag)
        defer { host.dispose() }
        try await lockFocusRestoreHost(host)
        let writesBefore = host.observed.repositoryWrites

        // when
        host.model.didTapReviewSettings()
        try requireSynchronousTransition(host, enabled: true)
        flag.isPresented = false
        renderFocusRestoreHost(host)
        let closedSynchronously = ownedPopovers(of: host.fixture.window).isEmpty
        let responderAtRender = String(describing: host.popover.firstResponder)
        await waitUntil(timeout: 8) { ownedPopovers(of: host.fixture.window).isEmpty && host.observed.events.contains("disappear") }
        try #require(ownedPopovers(of: host.fixture.window).isEmpty && host.observed.events.contains("disappear"),
                     "The composer removal must close the popover and disappear.")
        await settleFocusRestore()

        // then: whether the close preceded any restore opportunity is recorded; if it did not, this is characterisation
        expectNoRestore(host, writesBefore: writesBefore, "composer disappearance closedSynchronously=\(closedSynchronously) "
            + "responderAtRender=\(responderAtRender) dismantled=\(host.field.delegate == nil)")
        try expectNoStateModificationWarning(since: started)
    }

    @Test
    func givenAnotherResponderTookFocusDuringTheLock_whenTheComposerUnlocks_thenFocusIsNotStolen() async throws {
        // given
        let started = Date()
        let host = try await openFocusRestoreHost()
        defer { host.dispose() }
        let sentinel = try installRepositoryFocusSentinel(awayFrom: host.field, in: host.popover)
        try await lockFocusRestoreHost(host)
        try #require(host.popover.makeFirstResponder(sentinel))
        let writesBefore = host.observed.repositoryWrites

        // when
        try await unlockFocusRestoreHost(host)
        await settleFocusRestore()

        // then
        #expect(host.popover.firstResponder === sentinel, "The responder that took focus during the lock must keep it.")
        expectNoRestore(host, writesBefore: writesBefore, "other responder")
        try expectNoStateModificationWarning(since: started)
    }

    @Test
    func givenTheComposerLocksAgainBeforeTheRestoreRuns_whenItUnlocksLater_thenFocusIsNotRestored() async throws {
        // given
        let started = Date()
        let host = try await openFocusRestoreHost()
        defer { host.dispose() }
        try await lockFocusRestoreHost(host)
        let writesBefore = host.observed.repositoryWrites

        // when: the first unlock schedules a restore; Start must qualify again before the composer can lock a second time,
        // which needs the main actor, so that restore may already have run by then.
        host.model.didTapReviewSettings()
        try requireSynchronousTransition(host, enabled: true)
        try await requireEventually("Start to qualify again") { host.model.canStart }
        let restoredBeforeRelock = host.field.currentEditor() != nil
        host.model.didTapStart()
        try requireSynchronousTransition(host, enabled: false)
        try await requireEventually("the second refusal") { host.model.composerState == .refused }
        try await unlockFocusRestoreHost(host)
        await settleFocusRestore()

        // then: re-locking before the first attempt is not covered hosted, because qualification needs the main actor
        // and the first restore usually runs first; that branch asserts the second cycle restores in turn.
        let receipt = Comment(rawValue: "restoredBeforeRelock=\(restoredBeforeRelock) events=\(host.observed.events) "
            + "firstResponder=\(String(describing: host.popover.firstResponder))")
        #expect(host.observed.repositoryWrites == writesBefore, receipt)
        #expect(!host.observed.events.contains { $0.hasPrefix("commit:") }, receipt)
        #expect(host.useCase.directoryChecks.isEmpty, receipt)
        if restoredBeforeRelock {
            let live = try await awaitRestoredEditor(host)
            #expect(live.selectedRange == host.selectedBeforeLock, receipt)
        } else {
            #expect(host.field.currentEditor() == nil, receipt)
        }
        try expectNoStateModificationWarning(since: started)
    }

    @Test
    func givenFocusWasRestoredOnce_whenASecondLockStartsWithoutRepositoryFocus_thenItDoesNotRestoreAgain() async throws {
        // given
        let started = Date()
        let host = try await openFocusRestoreHost()
        defer { host.dispose() }
        try await lockFocusRestoreHost(host)
        try await unlockFocusRestoreHost(host)
        _ = try await awaitRestoredEditor(host)
        let sentinel = try installRepositoryFocusSentinel(awayFrom: host.field, in: host.popover)
        try #require(host.popover.makeFirstResponder(sentinel))
        try #require(host.popover.makeFirstResponder(nil))
        await settleFocusRestore()
        let writesBefore = host.observed.repositoryWrites

        // when: the second lock starts with focus on neither the field nor any other control
        try await lockFocusRestoreHost(host)
        try await unlockFocusRestoreHost(host)
        await settleFocusRestore()

        // then
        #expect(host.popover.firstResponder === host.popover, "Nothing may take focus when the second lock had no repository focus.")
        expectNoRestore(host, writesBefore: writesBefore, "two cycles")
        try expectNoStateModificationWarning(since: started)
    }
}
