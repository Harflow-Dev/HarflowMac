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
    func givenAnActiveRepositoryEditor_whenStartLocksThenSettingsUnlocksTheComposer_thenTheSameEditorAcceptsAnewEdit() async throws {
        // given
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

        // when: Start admission locks the composer; the fixture returns a classified refusal, then Review settings unlocks.
        model.didTapStart()
        await waitUntil(timeout: 8) { model.composerState == .refused }
        #expect(model.optionsLocked && useCase.directoryChecks.isEmpty)
        #expect(useCase.startProbes == [editedPath] && useCase.launchedRequests.count == 1)
        model.didTapReviewSettings()
        await waitUntil(timeout: 8) { !model.optionsLocked }
        await DisplayFrames.waitForPresentedFrame()

        // then: no explicit refocus after the lock transition.
        #expect(popover.isVisible && popover.isKeyWindow && ownedPopovers(of: fixture.window).contains { $0 === popover })
        #expect(field.currentEditor() === editor && popover.firstResponder === editor,
                "The mounted field editor must remain active through unlock, or this no-refocus acceptance case is incomplete.")
        try #require(field.currentEditor() === editor && popover.firstResponder === editor,
                     "Cannot type without refocusing because the native editor did not survive unlock.")
        #expect(editor.string.utf8.elementsEqual(model.repo.utf8), "The editor must match the current VM path after unlock.")
        #expect(useCase.directoryChecks.isEmpty, "Lock and unlock do not commit the pending field edit.")
        #expect(observed.repositoryWrites.count == 1, "Lock and unlock must not synthesize repository writes.")
        let replacementPath = "/fixture/repos/after-unlock"
        editor.insertText(replacementPath, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
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
        #expect(model.canStart && model.repoError == nil)
    }
}
