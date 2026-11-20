//
//  ModelPickerStatesHostedTests+RepositoryFinalBytes.swift
//  MainWindowFeatureTests
//

import AppKit
import Foundation
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import OSLog
import SwiftUI
import Testing

// MARK: - RepositoryFinalBytesClose

/// How a user dismisses the repository popover while the field editor holds bytes the view model has not seen.
enum RepositoryFinalBytesClose: CaseIterable, Sendable {
    case escape
    case mainWindowClick
}

// MARK: - RepositoryFinalBytesTransition

/// A state change after which the mounted field must still hand over its final bytes.
enum RepositoryFinalBytesTransition: CaseIterable, Sendable {
    case recentSelection
    case lockAndUnlock
}

// MARK: - ModelPickerStatesHostedTests + Repository final bytes

/// Hosted evidence that the repository field's final editor bytes reach the view model before Close or Start reads
/// them. Undelivered bytes are set with `editor.string = X`, which posts no change notification, and every stimulus is
/// real AppKit input. Ordering is observed through the forwarding view model, notifications and window state only.
extension ModelPickerStatesHostedTests {

    private static let finalBytes = "/fixture/repos/final-bytes"
    private static let finalBytesInitial = "/fixture/repos/initial"

    @MainActor
    private struct FinalBytesHost {
        let model: NewSessionVM
        let useCase: HostedListingUseCase
        let routing: MockNewSessionRouting
        let observed: RepositoryBindingObservedViewModel
        let fixture: Fixture
        let popover: NSWindow
        let field: NSTextField
        let editor: NSTextView
        /// The coordinator mounted as the field's delegate at setup.
        let mountedDelegate: AnyObject
        /// The bytes the one real keystroke delivered; the view model holds these until a flush delivers more.
        let typedBytes: String

        func dispose() {
            fixture.dispose()
            withExtendedLifetime(routing) {}
        }
    }

    private final class FinalBytesNotificationCounter: NSObject {
        var count = 0

        @objc func didPost(_ notification: Notification) { count += 1 }
    }

    private final class FinalBytesProbeStates {
        var delegateMountedAtWrite: [Bool] = []
        var delegateMountedAtCommit: [Bool] = []
    }

    private final class FinalBytesMouseCounter {
        var downs = 0
        var ups = 0
        /// Start's enablement and the popover's visibility as sampled just before the last dispatched mouse event
        /// (the mouse-up when one is dispatched), i.e. after the dismissal flush ran for the mouse-down.
        var canStartAtLastEvent: Bool?
        var popoverOpenAtLastEvent: Bool?
        var lastEvent = "none"
    }

    private func requireEventually(_ what: String, timeout: TimeInterval = 8, _ condition: @MainActor () -> Bool) async throws {
        await waitUntil(timeout: timeout, condition: condition)
        try #require(condition(), Comment(rawValue: "Timed out waiting for \(what)."))
    }

    private func countEndEditing(of field: NSTextField) -> FinalBytesNotificationCounter {
        let counter = FinalBytesNotificationCounter()
        NotificationCenter.default.addObserver(counter, selector: #selector(FinalBytesNotificationCounter.didPost(_:)),
                                               name: NSControl.textDidEndEditingNotification, object: field)
        return counter
    }

    /// The runtime warning is logged by the process itself, so a scan from the case's start catches a flush that
    /// writes state while SwiftUI is updating.
    private func expectNoStateModificationWarning(since start: Date) throws {
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let predicate = NSPredicate(format: "composedMessage CONTAINS %@", "Modifying state during view update")
        let hits = try Array(store.getEntries(at: store.position(date: start), matching: predicate))
        #expect(hits.isEmpty, "SwiftUI logged \(hits.count) 'Modifying state during view update' warning(s).")
    }

    private func openFinalBytesHost(refusesStart: Bool = false, states: FinalBytesProbeStates? = nil) async throws -> FinalBytesHost {
        let (model, useCase, routing) = makeRepositoryModel(repo: Self.finalBytesInitial, refusesStart: refusesStart)
        let observed = RepositoryBindingObservedViewModel(model)
        let fixture = makeFixture(observed, size: NSSize(width: 1280, height: 800), dark: false,
                                  harnessPresented: false, repositoryPresented: true)
        do {
            try await activate(fixture.window)
            try await requireEventually("the repository popover") { !ownedPopovers(of: fixture.window).isEmpty }
            let popover = try #require(ownedPopovers(of: fixture.window).first)
            let field = try #require(repositoryNativeField(in: popover))
            try #require(popover.makeFirstResponder(field))
            let editor = try #require(field.currentEditor() as? NSTextView)
            let mountedDelegate = try #require(field.delegate as AnyObject?)
            if let states {
                // Installed before the keystroke so every write, not only the flush, is attributed to the mounted coordinator.
                observed.writeProbe = { [weak field] in
                    states.delegateMountedAtWrite.append(field?.delegate as AnyObject? === mountedDelegate)
                }
                observed.commitProbe = { [weak field] in
                    states.delegateMountedAtCommit.append(field?.delegate as AnyObject? === mountedDelegate)
                }
            }
            // One real keystroke proves the coordinator tracks this editor before any undelivered bytes are set.
            let typed = Self.finalBytesInitial + "x"
            editor.insertText("x", replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
            try await requireEventually("the keystroke's repository write") { model.repo.utf8.elementsEqual(typed.utf8) }
            try #require(observed.repositoryWrites == [typed], "The typed character must be the only write so far.")
            try await requireEventually("Start to qualify") { model.canStart }
            await DisplayFrames.waitForPresentedFrame()
            try #require(popover.firstResponder === editor && field.currentEditor() === editor)
            return FinalBytesHost(model: model, useCase: useCase, routing: routing, observed: observed, fixture: fixture,
                                  popover: popover, field: field, editor: editor, mountedDelegate: mountedDelegate,
                                  typedBytes: typed)
        } catch {
            fixture.dispose()
            withExtendedLifetime(routing) {}
            throw error
        }
    }

    private func finalBytesChecks(_ host: FinalBytesHost, for path: String) -> Int {
        host.useCase.directoryChecks.filter { $0 == [path] }.count
    }

    private func sendFinalBytesEscape(to window: NSWindow) throws {
        try sendRepositoryProbeKey("\u{1B}", code: 53, to: window)
    }

    private func clickFinalBytes(at screenPoint: CGPoint, in window: NSWindow) throws {
        let events = try pointerBaselineMouseEvents(screenPoint, in: window)
        NSApp.postEvent(events.down, atStart: false)
        NSApp.postEvent(events.up, atStart: false)
        let queuedDown = try #require(NSApp.nextEvent(matching: [.leftMouseDown], until: Date().addingTimeInterval(1),
                                                      inMode: .default, dequeue: true))
        NSApp.sendEvent(queuedDown)
        if let queuedUp = NSApp.nextEvent(matching: [.leftMouseUp], until: .distantPast, inMode: .default, dequeue: true) {
            NSApp.sendEvent(queuedUp)
        }
    }

    private func inertMainWindowPoint(_ window: NSWindow) throws -> CGPoint {
        let layout = window.contentLayoutRect
        let point = window.convertPoint(toScreen: NSPoint(x: layout.minX + 12, y: layout.maxY - 12))
        var view: NSView? = try finalBytesHit(point, in: window)
        while let current = view {
            try #require(!(current is NSControl), "The inert click point must hit no control (\(type(of: current))).")
            view = current.superview
        }
        let interactive: Set<String> = [
            NSAccessibility.Role.button, .textField, .textArea, .popUpButton, .menuButton, .checkBox, .radioButton, .comboBox, .link
        ].reduce(into: []) { $0.insert($1.rawValue) }
        let covering = pointerBaselineTree(window).filter { element in
            guard let role = pointerBaselineString(element, key: "accessibilityRole"), interactive.contains(role),
                  let frame = finalBytesFrame(of: element) else { return false }
            return frame.contains(point)
        }
        try #require(covering.isEmpty, "The inert click point is inside \(covering.count) interactive accessibility element(s).")
        return point
    }

    private func finalBytesFrame(of element: NSObject) -> NSRect? {
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = element.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return value.rectValue
    }

    private func finalBytesHit(_ screenPoint: CGPoint, in window: NSWindow) throws -> NSView {
        let content = try #require(window.contentView)
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        return try #require(content.hitTest(content.convert(windowPoint, from: nil)), "No view at the click point.")
    }

    private func startButtonPoint(_ host: FinalBytesHost) async throws -> CGPoint {
        try await requireEventually("Start's accessibility frame") {
            pointerBaselineFrame(label: "Start task", in: host.fixture.window) != nil
        }
        await DisplayFrames.waitForPresentedFrame()
        let frame = try #require(pointerBaselineFrame(label: "Start task", in: host.fixture.window))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        _ = try finalBytesHit(point, in: host.fixture.window)
        return point
    }

    /// Counts the mouse events AppKit dispatches to the composer window while `body` runs.
    private func countingMouseEvents(
        in window: NSWindow, sample: @escaping @MainActor () -> (canStart: Bool, popoverOpen: Bool), _ body: () throws -> Void
    ) rethrows -> FinalBytesMouseCounter {
        let counter = FinalBytesMouseCounter()
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            if event.windowNumber == window.windowNumber {
                if event.type == .leftMouseDown { counter.downs += 1 } else { counter.ups += 1 }
                let state = sample()
                counter.canStartAtLastEvent = state.canStart
                counter.popoverOpenAtLastEvent = state.popoverOpen
                counter.lastEvent = event.type == .leftMouseDown ? "mouse-down" : "mouse-up"
            }
            return event
        }
        defer { monitor.map { NSEvent.removeMonitor($0) } }
        try body()
        return counter
    }

    private func popoverClosed(_ host: FinalBytesHost) -> Bool { ownedPopovers(of: host.fixture.window).isEmpty }

    private func commandReturn(for window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36
        ))
    }

    /// Command-Return is dispatched through the application's own queue so `NSApp.currentEvent` is the real event.
    private func sendStartShortcut(_ host: FinalBytesHost) async throws {
        let before = host.observed.startTapCount
        NSApp.postEvent(try commandReturn(for: host.popover), atStart: false)
        let queued = try #require(NSApp.nextEvent(matching: [.keyDown], until: Date().addingTimeInterval(1),
                                                  inMode: .default, dequeue: true))
        NSApp.sendEvent(queued)
        try await requireEventually(
            "Command-Return to reach Start from the key popover; if it never does, that is a product finding against R7 check 3 "
                + "(shortcut from the key popover), not a test defect",
            timeout: 4
        ) { host.observed.startTapCount > before }
    }

    // MARK: H1

    @Test(arguments: RepositoryFinalBytesClose.allCases)
    func givenUndeliveredEditorBytes_whenTheUserDismissesThePopover_thenTheCommitSeesTheFinalBytesOnce(
        _ close: RepositoryFinalBytesClose
    ) async throws {
        // given
        let started = Date()
        let states = FinalBytesProbeStates()
        let host = try await openFinalBytesHost(states: states)
        defer { host.dispose() }
        let ended = countEndEditing(of: host.field)
        defer { NotificationCenter.default.removeObserver(ended) }
        let final = Self.finalBytes
        let typed = host.typedBytes
        let clickPoint = close == .mainWindowClick ? try inertMainWindowPoint(host.fixture.window) : .zero
        host.editor.string = final

        // when
        switch close {
        case .escape: try sendFinalBytesEscape(to: host.popover)
        case .mainWindowClick: try clickFinalBytes(at: clickPoint, in: host.fixture.window)
        }
        try await requireEventually("the popover to close and the final bytes to be checked") {
            popoverClosed(host) && finalBytesChecks(host, for: final) >= 1
        }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let receipt = Comment(rawValue: "events=\(host.observed.events) endEditing=\(ended.count) "
            + "delegateAtWrite=\(states.delegateMountedAtWrite) delegateAtCommit=\(states.delegateMountedAtCommit)")
        #expect(host.observed.repoAtCommit.first?.utf8.elementsEqual(final.utf8) == true, receipt)
        #expect(host.observed.events.filter { $0.hasPrefix("write:") || $0.hasPrefix("commit:") }
            == ["write:" + typed, "write:" + final, "commit:" + final], receipt)
        #expect(states.delegateMountedAtWrite == [true, true], "Every write must come from the mounted coordinator. \(receipt)")
        #expect(states.delegateMountedAtCommit.count == 1, receipt)
        #expect(finalBytesChecks(host, for: final) == 1, receipt)
        #expect(finalBytesChecks(host, for: typed) == 0 && finalBytesChecks(host, for: Self.finalBytesInitial) == 0, receipt)
        #expect(host.observed.repositoryWrites.map { Array($0.utf8) } == [Array(typed.utf8), Array(final.utf8)],
                "No write may follow the close.")
        #expect(host.model.repo.utf8.elementsEqual(final.utf8))
        try expectNoStateModificationWarning(since: started)
    }

    // MARK: H2

    @Test
    func givenFocusAlreadyLeftTheField_whenThePopoverIsDismissedBeforeTheDeferredBlurRuns_thenTheFinalBytesAreCheckedOnce() async throws {
        // given
        let host = try await openFinalBytesHost()
        defer { host.dispose() }
        let ended = countEndEditing(of: host.field)
        defer { NotificationCenter.default.removeObserver(ended) }
        let sentinel = try installRepositoryFocusSentinel(awayFrom: host.field, in: host.popover)
        defer { sentinel.removeFromSuperview() }
        let final = Self.finalBytes
        let typed = host.typedBytes
        host.editor.string = final

        // when: focus leaves and the popover closes with no yield in between. The layout passes are best effort; a
        // SwiftUI-driven update before Escape cannot be proven without yielding, which would let the deferred blur
        // run, so this case does not claim one.
        try #require(host.popover.makeFirstResponder(sentinel))
        host.fixture.host.layoutSubtreeIfNeeded()
        host.fixture.window.displayIfNeeded()
        host.popover.displayIfNeeded()
        #expect(ended.count == 1 && host.field.currentEditor() == nil && host.popover.firstResponder === sentinel,
                "The departure must have ended editing before Escape.")
        #expect(host.observed.repositoryWrites == [typed], "Nothing may have been delivered before the close.")
        try sendFinalBytesEscape(to: host.popover)
        try await requireEventually("the popover to close and the final bytes to be checked") {
            popoverClosed(host) && finalBytesChecks(host, for: final) >= 1
        }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let receipt = Comment(rawValue: "events=\(host.observed.events)")
        #expect(finalBytesChecks(host, for: final) == 1, receipt)
        #expect(host.observed.repositoryWrites.map { Array($0.utf8) } == [Array(typed.utf8), Array(final.utf8)], receipt)
        #expect(host.model.repo.utf8.elementsEqual(final.utf8))
    }

    // MARK: H3

    @Test
    func givenUndeliveredEditorBytes_whenStartIsClickedWithThePopoverOpen_thenNoStaleStartRunsAndTheNextStartUsesTheFinalBytes() async throws {
        // given
        let started = Date()
        let host = try await openFinalBytesHost()
        defer { host.dispose() }
        let startPoint = try await startButtonPoint(host)
        let final = Self.finalBytes
        host.editor.string = final

        // when
        let first = try countingMouseEvents(
            in: host.fixture.window,
            sample: { (host.model.canStart, !popoverClosed(host)) }
        ) {
            try clickFinalBytes(at: startPoint, in: host.fixture.window)
        }
        try await requireEventually("the popover to close and the final bytes to be checked") {
            popoverClosed(host) && finalBytesChecks(host, for: final) >= 1
        }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let delivered = host.observed.startTapCount
        let disabledAtLastEvent = first.canStartAtLastEvent == false
        let branch = disabledAtLastEvent ? "start-disabled-at-\(first.lastEvent)" : "start-enabled-at-\(first.lastEvent)"
        let receipt = Comment(rawValue: "branch=\(branch) popoverOpenAtLastEvent=\(String(describing: first.popoverOpenAtLastEvent)) "
            + "mouseDowns=\(first.downs) mouseUps=\(first.ups) startTaps=\(delivered) "
            + "events=\(host.observed.events) probes=\(host.useCase.startProbes)")
        #expect(first.downs == 1, receipt)
        #expect(delivered == (disabledAtLastEvent ? 0 : 1),
                "Start must be delivered once unless it was disabled when the press ended. \(receipt)")
        #expect(!host.useCase.startProbes.contains(host.typedBytes), "Start must never run on the stale bytes. \(receipt)")
        #expect(finalBytesChecks(host, for: final) == 1, receipt)
        #expect(host.model.repo.utf8.elementsEqual(final.utf8), receipt)

        // when: a second, real Start once qualification has settled for the final bytes
        try await requireEventually("qualification to settle for the final bytes") { host.model.canStart && popoverClosed(host) }
        let before = host.observed.startTapCount
        try clickFinalBytes(at: startPoint, in: host.fixture.window)
        try await requireEventually("the second Start's preflight") { host.useCase.startProbes == [final] }

        // then
        #expect(host.observed.startTapCount == before + 1, receipt)
        #expect(host.useCase.startProbes == [final], receipt)
        try expectNoStateModificationWarning(since: started)
    }

    @Test
    func givenUndeliveredEditorBytes_whenCommandReturnStartsWithThePopoverOpen_thenTheViewModelHoldsTheFinalBytesBeforeStart() async throws {
        // given
        let started = Date()
        let host = try await openFinalBytesHost()
        defer { host.dispose() }
        let final = Self.finalBytes
        let typed = host.typedBytes
        host.editor.string = final

        // when
        try await sendStartShortcut(host)
        try await requireEventually("the final bytes to reach the view model") { host.model.repo.utf8.elementsEqual(final.utf8) }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let dismissed = popoverClosed(host)
        let events = host.observed.events
        let receipt = Comment(rawValue: "dismissed=\(dismissed) events=\(events)")
        let writeIndex = try #require(events.firstIndex(of: "write:" + final), receipt)
        let startIndex = try #require(events.firstIndex(of: "start"), receipt)
        #expect(writeIndex < startIndex, "The flush must deliver the final bytes before Start reads them. \(receipt)")
        #expect(dismissed || !events[..<startIndex].contains { $0.hasPrefix("commit:") },
                "No commit may precede Start unless the shortcut dismissed the popover. \(receipt)")
        #expect(!host.useCase.startProbes.contains(typed), "Start must never run on the stale bytes. \(receipt)")
        #expect(finalBytesChecks(host, for: final) == (dismissed ? 1 : 0), receipt)

        // when: a later, qualified Start
        if host.useCase.startProbes.isEmpty {
            try await requireEventually("qualification to settle for the final bytes") { host.model.canStart }
            try await sendStartShortcut(host)
        }
        try await requireEventually("the later Start's preflight") { host.useCase.startProbes == [final] }

        // then
        #expect(host.useCase.startProbes == [final], receipt)
        try expectNoStateModificationWarning(since: started)
    }

    // MARK: H4

    /// The binding setter's call during teardown cannot be observed without a production seam; a flush from it would
    /// deliver the final bytes, which shows as a write and is forbidden here.
    @Test
    func givenUndeliveredEditorBytes_whenTheComposerIsRemovedWithoutAClose_thenNothingIsDeliveredOrChecked() async throws {
        // given
        let host = try await openFinalBytesHost()
        defer { host.dispose() }
        let ended = countEndEditing(of: host.field)
        defer { NotificationCenter.default.removeObserver(ended) }
        let final = Self.finalBytes
        let outgoing = try #require(host.field.delegate, "The mounted coordinator must be the field's delegate.")
        host.editor.string = final
        let writesBefore = host.observed.repositoryWrites
        let checksBefore = host.useCase.directoryChecks

        // when
        host.fixture.window.contentView = NSView(frame: NSRect(origin: .zero, size: host.fixture.window.frame.size))
        try await requireEventually("the composer's disappearance") { host.observed.events.contains("disappear") }
        try await requireEventually("the field to be dismantled") { host.field.delegate == nil }
        await DisplayFrames.waitForPresentedFrame()
        let receipt = Comment(rawValue: "events=\(host.observed.events) endEditing=\(ended.count)")
        #expect(host.observed.repositoryWrites == writesBefore, receipt)

        // when: an authenticated end-editing callback reaches the outgoing coordinator after dismantle
        outgoing.controlTextDidEndEditing?(Notification(
            name: NSControl.textDidEndEditingNotification, object: host.field, userInfo: ["NSFieldEditor": host.editor]
        ))
        await Task.yield()
        await DisplayFrames.waitForPresentedFrame()

        // then
        #expect(host.observed.repositoryWrites == writesBefore, receipt)
        #expect(!host.observed.events.contains { $0.hasPrefix("commit:") }, receipt)
        #expect(host.useCase.directoryChecks == checksBefore, receipt)
        #expect(finalBytesChecks(host, for: final) == 0, receipt)
        #expect(host.model.repo.utf8.elementsEqual(host.typedBytes.utf8), receipt)
    }

    // MARK: H5

    @Test
    func givenUndeliveredEditorBytes_whenAnUnrelatedChangeRerendersThePopover_thenTheEditorKeepsThemAndCloseChecksThem() async throws {
        // given
        let host = try await openFinalBytesHost()
        defer { host.dispose() }
        let final = Self.finalBytes
        host.editor.string = final

        // when: an unrelated view model change re-renders the popover's field
        let help = "Hosted unrelated re-render"
        host.model.repoError = help
        try await requireEventually("the popover to re-render") { host.field.accessibilityHelp() == help }

        // then
        #expect(host.field.currentEditor() === host.editor)
        #expect(host.editor.string.utf8.elementsEqual(final.utf8), "A re-render must not replace bytes the view model has not seen.")

        // when
        try sendFinalBytesEscape(to: host.popover)
        try await requireEventually("the popover to close and the final bytes to be checked") {
            popoverClosed(host) && finalBytesChecks(host, for: final) >= 1
        }
        await DisplayFrames.waitForPresentedFrame()

        // then
        #expect(finalBytesChecks(host, for: final) == 1, Comment(rawValue: "events=\(host.observed.events)"))
        #expect(host.model.repo.utf8.elementsEqual(final.utf8))
    }

    // MARK: H6

    @Test(arguments: RepositoryFinalBytesTransition.allCases)
    func givenARecentSelectionOrAnUnlock_whenTheUserTypesThenDismisses_thenTheFinalBytesAreStillChecked(
        _ transition: RepositoryFinalBytesTransition
    ) async throws {
        // given
        let host = try await openFinalBytesHost(refusesStart: transition == .lockAndUnlock)
        defer { host.dispose() }
        switch transition {
        case .recentSelection:
            let selected = "/fixture/repos/selected-from-recents"
            host.model.didTapRecentRepo(selected)
            try await requireEventually("the selection to reach the editor") { host.editor.string.utf8.elementsEqual(selected.utf8) }
        case .lockAndUnlock:
            host.model.didTapStart()
            try await requireEventually("the refusal") { host.model.composerState == .refused }
            try await requireEventually("the native field to lock") { host.model.optionsLocked && !host.field.isEnabled }
            host.model.didTapReviewSettings()
            try await requireEventually("the native field to unlock") { !host.model.optionsLocked && host.field.isEnabled }
            await DisplayFrames.waitForPresentedFrame()
        }
        try #require(host.field.currentEditor() === host.editor && host.popover.firstResponder === host.editor,
                     "The editor must survive the transition without a refocus.")
        let typed = "/fixture/repos/typed-after-transition"
        host.editor.insertText(typed, replacementRange: NSRange(location: 0, length: host.editor.string.utf16.count))
        try await requireEventually("the typed bytes to reach the view model") { host.model.repo.utf8.elementsEqual(typed.utf8) }
        let final = Self.finalBytes
        host.editor.string = final

        // when
        try sendFinalBytesEscape(to: host.popover)
        try await requireEventually("the popover to close and the final bytes to be checked") {
            popoverClosed(host) && finalBytesChecks(host, for: final) >= 1
        }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let receipt = Comment(rawValue: "events=\(host.observed.events)")
        #expect(finalBytesChecks(host, for: final) == 1, receipt)
        #expect(host.observed.repoAtCommit.last?.utf8.elementsEqual(final.utf8) == true, receipt)
        #expect(host.model.repo.utf8.elementsEqual(final.utf8))
    }
}
