import AppKit
import Foundation
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import SwiftUI
import Testing

// MARK: - ModelPickerStatesHostedTests + Repository lock lifecycle

@MainActor
extension ModelPickerStatesHostedTests {
    func sendRepositoryProbeKey(_ text: String, code: UInt16, to window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: text,
            charactersIgnoringModifiers: text, isARepeat: false, keyCode: code
        ))
        window.sendEvent(event)
    }

    @Test
    func givenAnActiveRepositoryEditor_whenStartLocksThenSettingsUnlocksTheComposer_thenTheRestoredLiveEditorAcceptsAnewEdit() async throws {
        // given
        let started = Date()
        let (model, useCase, routing) = makeRepositoryModel(repo: "/fixture/repos/initial", refusesStart: true)
        defer { withExtendedLifetime(routing) {} }
        let observed = RepositoryBindingObservedViewModel(model)
        let fixture = makeFixture(observed, size: NSSize(width: 1280, height: 800), dark: false,
                                  harnessPresented: false, repositoryPresented: true)
        defer { fixture.dispose() }
        try await activate(fixture.window)
        await waitUntil(timeout: 8) { !ownedPopovers(of: fixture.window).isEmpty }
        let popover = try #require(ownedPopovers(of: fixture.window).first)
        let field = try #require(repositoryNativeField(in: popover))
        try #require(popover.makeFirstResponder(field))
        let editor = try #require(field.currentEditor() as? NSTextView)
        let editedPath = "/fixture/repos/pending-before-lock"
        editor.insertText(editedPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await waitUntil(timeout: 8) { model.repo.utf8.elementsEqual(editedPath.utf8) && model.canStart }
        #expect(observed.repositoryWrites.count == 1 && observed.repositoryWrites[0].utf8.elementsEqual(editedPath.utf8))
        #expect(model.hasUncommittedRepoEdit && useCase.directoryChecks.isEmpty)
        #expect(popover.firstResponder === editor && field.currentEditor() === editor)
        let selectedBeforeLock = editor.selectedRange

        // when: Start admission locks the composer; the fixture returns a classified refusal, then Review settings unlocks.
        model.didTapStart()
        fixture.host.layoutSubtreeIfNeeded()
        fixture.window.displayIfNeeded()
        popover.displayIfNeeded()
        try #require(!field.isEnabled, "The native field must be disabled synchronously after the lock.")
        await waitUntil(timeout: 8) { model.composerState == .refused }
        #expect(model.optionsLocked && useCase.directoryChecks.isEmpty)
        #expect(useCase.startProbes == [editedPath] && useCase.launchedRequests.count == 1)
        model.didTapReviewSettings()
        fixture.host.layoutSubtreeIfNeeded()
        fixture.window.displayIfNeeded()
        popover.displayIfNeeded()
        try #require(field.isEnabled, "The native field must be enabled synchronously after the unlock.")
        await waitUntil(timeout: 8) { !model.optionsLocked }
        await DisplayFrames.waitForPresentedFrame()

        // then: native focus is restored without an explicit refocus; the live editor may be a replacement.
        await waitUntil(timeout: 8) { field.currentEditor() != nil && popover.firstResponder === field.currentEditor() }
        #expect(popover.isVisible && popover.isKeyWindow && ownedPopovers(of: fixture.window).contains { $0 === popover })
        let live = try #require(field.currentEditor() as? NSTextView,
                                "Native focus was not restored after unlock: acceptance incomplete.")
        try #require(popover.firstResponder === live, "The live editor must be the first responder after unlock.")
        let identity = Comment(rawValue: live === editor ? "live editor is the original object" : "live editor is a replacement object")
        #expect(live.string.utf8.elementsEqual(model.repo.utf8), identity)
        #expect(live.selectedRange == selectedBeforeLock, identity)
        #expect(useCase.directoryChecks.isEmpty, "Lock and unlock do not commit the pending field edit.")
        #expect(observed.repositoryWrites.count == 1, "Lock and unlock must not synthesize repository writes.")
        let replacementPath = "/fixture/repos/after-unlock"
        live.insertText(replacementPath, replacementRange: NSRange(location: 0, length: live.string.utf16.count))
        await waitUntil(timeout: 8) { model.repo.utf8.elementsEqual(replacementPath.utf8) }
        #expect(model.repo.utf8.elementsEqual(replacementPath.utf8) && model.hasUncommittedRepoEdit)
        #expect(observed.repositoryWrites.map { Array($0.utf8) } == [
            Array(editedPath.utf8), Array(replacementPath.utf8)
        ])
        #expect(useCase.directoryChecks.isEmpty)
        let focusTarget = try installRepositoryFocusSentinel(awayFrom: field, in: popover)
        try #require(popover.makeFirstResponder(focusTarget))
        await waitUntil(timeout: 8) { useCase.directoryChecks == [[replacementPath]] }
        #expect(useCase.directoryChecks == [[replacementPath]])
        await waitUntil(timeout: 8) { model.canStart }
        #expect(model.canStart && model.repoError == nil)
        try expectNoStateModificationWarning(since: started)
    }
}
