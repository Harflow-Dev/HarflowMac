//
//  TaskPaneChipFocusTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

// MARK: - TaskPaneChipFocusTests

/// The decision and the deferred run of the native chip focus return, driven by scripted surfaces: no window, no toolbar and
/// no desktop. Which responder AppKit really accepts is checked in the hosted top bar suite, not here.
@MainActor
struct TaskPaneChipFocusTests {
    private typealias Focus = TaskPaneChipFocus
    private typealias Surface = TaskPaneChipFocus.Surface

    private static let inPane = PaneFocusSnapshot(axFocusInPane: true, nativeFocusInDetail: false, window: nil)

    /// An eligible surface: current, same window, key, no sheet, no input, nothing live, a chip target present.
    private static func eligible(_ responder: Focus.Responder = .outsideDetail) -> Surface {
        Surface(requestIsCurrent: true, sameWindow: true, windowIsKey: true, sheetAttached: false, userInputSinceClose: false,
                responder: responder, hasTarget: true)
    }

    /// Scripts the surfaces a run reads in order and records what it did.
    @MainActor private final class Script {
        var surfaces: [Surface]
        var reads = 0
        var chipCalls = 0
        var windowCalls = 0
        var bindingCalls = 0
        var chipAccepts: Bool
        var windowAccepts: Bool

        init(_ surfaces: [Surface], chipAccepts: Bool = true, windowAccepts: Bool = true) {
            self.surfaces = surfaces
            self.chipAccepts = chipAccepts
            self.windowAccepts = windowAccepts
        }

        func run(_ snapshot: PaneFocusSnapshot? = TaskPaneChipFocusTests.inPane) async -> Focus.Outcome {
            await Focus.run(
                snapshot: snapshot,
                surface: { [self] in
                    defer { reads += 1 }
                    return surfaces[min(reads, surfaces.count - 1)]
                },
                applyBindings: { [self] in bindingCalls += 1 },
                focusChip: { [self] in chipCalls += 1; return chipAccepts },
                focusWindow: { [self] in windowCalls += 1; return windowAccepts }
            )
        }
    }

    // MARK: - Mapping

    @Test func givenEachOrigin_whenMapped_thenOnlyTheChipsHaveAToolbarIdentifier() {
        // then
        #expect(Focus.toolbarIdentifier(for: .chipContinuity) == "task-detail.chip.continuity")
        #expect(Focus.toolbarIdentifier(for: .chipNotices) == "task-detail.chip.notices")
        #expect(Focus.toolbarIdentifier(for: .chipAccess) == "task-detail.chip.access")
        #expect(Focus.toolbarIdentifier(for: .continuityDetails) == nil)
        #expect(Focus.toolbarIdentifier(for: .notices) == nil)
    }

    // MARK: - Veto

    @Test func givenAnEligibleSurface_whenChecked_thenNothingVetoesAndEveryOtherResponderButALiveControlIsAllowed() {
        // then
        for responder in [Focus.Responder.chip, .detailHost, .nowhere, .outsideDetail] {
            #expect(Focus.veto(Self.eligible(responder)) == nil, "\(responder)")
        }
        #expect(Focus.veto(Self.eligible(.liveControl)) == .focusMoved)
    }

    @Test func givenEachWayTheSituationChanges_whenChecked_thenItVetoesWithItsReason() {
        // given
        var stale = Self.eligible(); stale.requestIsCurrent = false
        var otherWindow = Self.eligible(); otherWindow.sameWindow = false
        var notKey = Self.eligible(); notKey.windowIsKey = false
        var sheet = Self.eligible(); sheet.sheetAttached = true
        var input = Self.eligible(); input.userInputSinceClose = true

        // then
        #expect(Focus.veto(stale) == .staleRequest)
        #expect(Focus.veto(otherWindow) == .windowChanged)
        #expect(Focus.veto(notKey) == .windowNotKey)
        #expect(Focus.veto(sheet) == .sheetOpen)
        #expect(Focus.veto(input) == .userInput)
        #expect(Focus.veto(Surface()) == .staleRequest, "the default surface never proceeds")
    }

    // MARK: - Run

    @Test func givenFocusWasNotInThePane_whenRun_thenNothingIsReadOrChanged() async {
        // given
        let script = Script([Self.eligible()])
        let elsewhere = PaneFocusSnapshot(axFocusInPane: false, nativeFocusInDetail: false, window: nil)

        // when
        let outcome = await script.run(elsewhere)
        let missing = await script.run(nil)

        // then
        #expect(outcome == .skipped(.notInPane) && missing == .skipped(.notInPane))
        #expect(script.reads == 0 && script.chipCalls == 0 && script.windowCalls == 0 && script.bindingCalls == 0)
    }

    @Test func givenAnEligibleCurrentRequest_whenRun_thenTheChipTakesFocusOnceAndTheWindowIsLeftAlone() async {
        // given
        let script = Script([Self.eligible(.outsideDetail)])

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .focusedChip)
        #expect(script.chipCalls == 1 && script.windowCalls == 0 && script.bindingCalls == 1)
    }

    @Test func givenFocusAlreadyOnTheChip_whenRun_thenNothingIsMoved() async {
        // given
        let script = Script([Self.eligible(.chip)])

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .focusedChip)
        #expect(script.chipCalls == 0 && script.windowCalls == 0)
        #expect(script.bindingCalls == 1, "the accessibility binding still applies when the keyboard is already on the chip")
    }

    @Test func givenThePlatformRefusesTheChip_whenTheRequestIsStillEligible_thenTheOriginatingWindowTakesFocus() async {
        // given
        let script = Script([Self.eligible(.outsideDetail)], chipAccepts: false)

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .fellBackToWindow)
        #expect(script.chipCalls == 1 && script.windowCalls == 1 && script.bindingCalls == 1)
    }

    @Test func givenNoSuitableChipResponder_whenRun_thenOnlyTheWindowFallbackRuns() async {
        // given
        var surface = Self.eligible(.outsideDetail)
        surface.hasTarget = false
        let script = Script([surface])

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .fellBackToWindow)
        #expect(script.chipCalls == 0 && script.windowCalls == 1)
    }

    @Test func givenTheWindowIsAlreadyTheResponder_whenTheChipIsRefused_thenNoFurtherChangeIsMade() async {
        // given
        let script = Script([Self.eligible(.nowhere)], chipAccepts: false)

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .fellBackToWindow)
        #expect(script.windowCalls == 0)
    }

    @Test func givenBothRefuse_whenRun_thenTheOutcomeIsRefusedAndNothingIsAssumed() async {
        // given
        let script = Script([Self.eligible()], chipAccepts: false, windowAccepts: false)

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .refused)
    }

    // MARK: - Deferred revalidation

    @Test func givenTheSelectionChangedOrANewRevealArrivedDuringTheDeferral_whenRun_thenNothingChanges() async {
        // given the request is stale by the first read after the deferral
        var stale = Self.eligible()
        stale.requestIsCurrent = false
        let script = Script([stale])

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .skipped(.staleRequest))
        #expect(script.chipCalls == 0 && script.windowCalls == 0)
        #expect(script.bindingCalls == 0, "a stale request assigns no SwiftUI focus either")
    }

    @Test func givenTheRequestGoesStaleAfterTheChipWasRefused_whenRun_thenTheWindowFallbackIsNotTaken() async {
        // given eligible at the first two reads, stale at the third (the pane was reopened meanwhile)
        var stale = Self.eligible()
        stale.requestIsCurrent = false
        let script = Script([Self.eligible(), Self.eligible(), stale], chipAccepts: false)

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .skipped(.staleRequest))
        #expect(script.chipCalls == 1 && script.windowCalls == 0)
    }

    @Test func givenTheChipDisappearsDuringTheRun_whenRefused_thenTheOriginatingWindowIsTheOnlyFallback() async {
        // given the target exists until the chip is tried and is gone at the next read
        var gone = Self.eligible(.outsideDetail)
        gone.hasTarget = false
        let script = Script([Self.eligible(.outsideDetail), Self.eligible(.outsideDetail), gone], chipAccepts: false)

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .fellBackToWindow)
        #expect(script.chipCalls == 1 && script.windowCalls == 1)
    }

    @Test func givenThePersonMovedFocusToALiveControl_whenRun_thenNeitherTargetIsTouched() async {
        // given
        let script = Script([Self.eligible(.liveControl)])

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .skipped(.focusMoved))
        #expect(script.chipCalls == 0 && script.windowCalls == 0 && script.bindingCalls == 0)
    }

    @Test func givenTheFocusMovesToALiveControlAfterTheChipWasRefused_whenRun_thenTheWindowIsNotTaken() async {
        // given
        let script = Script([Self.eligible(.outsideDetail), Self.eligible(.outsideDetail), Self.eligible(.liveControl)], chipAccepts: false)

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .skipped(.focusMoved))
        #expect(script.windowCalls == 0)
    }

    @Test(arguments: [0, 1, 2, 3])
    func givenTheWindowOrInputChanged_whenRun_thenNothingChanges(change: Int) async {
        // given
        var surface = Self.eligible()
        let expected: Focus.Reason
        switch change {
        case 0: surface.sameWindow = false; expected = .windowChanged
        case 1: surface.windowIsKey = false; expected = .windowNotKey
        case 2: surface.sheetAttached = true; expected = .sheetOpen
        default: surface.userInputSinceClose = true; expected = .userInput
        }
        let script = Script([surface])

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .skipped(expected))
        #expect(script.chipCalls == 0 && script.windowCalls == 0 && script.bindingCalls == 0)
    }

    @Test func givenTheTaskWasCancelled_whenRun_thenNothingIsReadOrChanged() async {
        // given a mounted view that disappeared
        let script = Script([Self.eligible()])
        let task = Task { @MainActor in await script.run() }
        task.cancel()

        // when
        let outcome = await task.value

        // then
        #expect(outcome == .skipped(.staleRequest))
        #expect(script.reads == 0 && script.chipCalls == 0 && script.windowCalls == 0 && script.bindingCalls == 0)
    }

    // MARK: - Bindings share the eligibility

    @Test(arguments: [0, 1, 2, 3, 4])
    func givenSomethingChangesBetweenTheBindingsAndTheNativeStep_whenRun_thenTheBindingsRanOnceAndNothingNativeFollows(change: Int) async {
        // given eligible when the bindings are applied, then one change before the chip is tried
        var later = Self.eligible()
        let expected: Focus.Reason
        switch change {
        case 0: later.userInputSinceClose = true; expected = .userInput
        case 1: later.sameWindow = false; expected = .windowChanged
        case 2: later.sheetAttached = true; expected = .sheetOpen
        case 3: later.requestIsCurrent = false; expected = .staleRequest
        default: later.responder = .liveControl; expected = .focusMoved
        }
        let script = Script([Self.eligible(), later])

        // when
        let outcome = await script.run()

        // then
        #expect(outcome == .skipped(expected))
        #expect(script.bindingCalls == 1 && script.chipCalls == 0 && script.windowCalls == 0)
    }

    @Test func givenTheTaskIsCancelledAfterTheBindingsDeferral_whenRun_thenNoBindingIsAssigned() async {
        // given a mounted view that disappears while the run waits to apply its bindings
        let script = Script([Self.eligible()])
        let task = Task { @MainActor in
            await Task.yield()
            return await script.run()
        }
        task.cancel()

        // when
        let outcome = await task.value

        // then
        #expect(outcome == .skipped(.staleRequest))
        #expect(script.bindingCalls == 0 && script.chipCalls == 0 && script.windowCalls == 0)
    }

    // MARK: - Accessibility ownership

    /// A scripted accessibility tree of plain objects: labels, parents, frames and windows by node.
    @MainActor private final class Tree {
        var labels: [ObjectIdentifier: String] = [:]
        var parents: [ObjectIdentifier: NSObject] = [:]
        var frames: [ObjectIdentifier: CGRect] = [:]
        var windows: [ObjectIdentifier: NSObject] = [:]
        var focused: NSObject?
        var ownedPanes: [NSObject] = []

        func node(_ label: String?, parent: NSObject? = nil, frame: CGRect? = nil, window: NSObject? = nil) -> NSObject {
            let node = NSObject()
            let id = ObjectIdentifier(node)
            if let label { labels[id] = label }
            if let parent { parents[id] = parent }
            if let frame { frames[id] = frame }
            if let window { windows[id] = window }
            return node
        }

        var reader: Focus.AccessibilityReader {
            Focus.AccessibilityReader(
                focused: { [self] in focused },
                label: { [self] in labels[ObjectIdentifier($0)] },
                parent: { [self] in parents[ObjectIdentifier($0)] },
                frame: { [self] in frames[ObjectIdentifier($0)] },
                window: { [self] in windows[ObjectIdentifier($0)] },
                panesInOwner: { [self] in ownedPanes }
            )
        }
    }

    private static let region = CGRect(x: 100, y: 100, width: 1000, height: 700)
    private static let paneFrame = CGRect(x: 680, y: 100, width: 420, height: 700)

    /// A pane in `window` holding a focused group header. `listedByOwner` puts that very pane element in the owner's own tree.
    private func ownedFocus(window: NSObject?, paneFrame: CGRect = paneFrame, listedByOwner: Bool = true) -> Tree {
        let tree = Tree()
        let pane = tree.node("Task details", frame: paneFrame, window: window)
        let header = tree.node("Notices, 3", parent: pane, window: window)
        tree.focused = header
        tree.ownedPanes = listedByOwner ? [pane] : []
        return tree
    }

    @Test func givenTheFocusedHeaderIsInThePaneOfTheMountedWindow_whenChecked_thenItIsOwned() {
        // given
        let owner = NSObject()
        let tree = ownedFocus(window: owner)

        // then
        #expect(Focus.focusIsInOwnedPane(tree.reader, owner: owner, region: Self.region))
    }

    @Test func givenAPaneThatReportsNoWindow_whenTheOwnersOwnTreeContainsThatVeryElement_thenItIsOwned() {
        // given the platform reports no window for SwiftUI nodes: element identity in the owner's rooted traversal is the proof
        let owner = NSObject()
        let tree = ownedFocus(window: nil)

        // then
        #expect(Focus.focusIsInOwnedPane(tree.reader, owner: owner, region: Self.region))
    }

    @Test func givenAPaneThatPositivelyReportsTheOriginatingWindow_whenTheOwnersTraversalDoesNotListIt_thenItIsOwned() {
        // given
        let owner = NSObject()
        let tree = ownedFocus(window: owner, listedByOwner: false)

        // then
        #expect(Focus.focusIsInOwnedPane(tree.reader, owner: owner, region: Self.region))
    }

    @Test func givenTwoWindowsWithSameFramePanesAndNoReportedWindow_whenTheOtherPaneHoldsFocus_thenFrameEqualityDoesNotAuthorize() {
        // given the owner's tree holds its own pane at the same frame, but the focused pane is a different element in another
        // window, and neither reports a window
        let owner = NSObject()
        let mine = ownedFocus(window: nil)
        let theirs = ownedFocus(window: nil, listedByOwner: false)
        theirs.ownedPanes = mine.ownedPanes

        // then the frames are identical, the elements are not: not owned
        #expect(mine.frames.values.first == theirs.frames.values.first)
        #expect(!Focus.focusIsInOwnedPane(theirs.reader, owner: owner, region: Self.region))
        #expect(Focus.focusIsInOwnedPane(mine.reader, owner: owner, region: Self.region))
    }

    @Test func givenAnotherWindowsPaneHoldsTheAccessibilityFocus_whenChecked_thenItDoesNotAuthorizeAReturn() {
        // given a second pane labelled "Task details" in another window has the accessibility focus
        let owner = NSObject()
        let other = NSObject()
        let tree = ownedFocus(window: other)

        // then
        #expect(!Focus.focusIsInOwnedPane(tree.reader, owner: owner, region: Self.region))
    }

    @Test func givenAnotherPaneThatSharesTheLabelAndSitsOutsideTheRegion_whenChecked_thenItIsNotOwned() {
        // given the same label in the owner's window but outside the mounted anchor's region
        let owner = NSObject()
        let tree = ownedFocus(window: owner, paneFrame: CGRect(x: 2000, y: 100, width: 420, height: 700))

        // then
        #expect(!Focus.focusIsInOwnedPane(tree.reader, owner: owner, region: Self.region))
    }

    @Test func givenAPaneWithNoWindowThatTheOwnersTreeDoesNotContain_whenChecked_thenOwnershipIsNotAssumed() {
        // given it reports no window and is not an element of the owner's tree: unknown ownership is not owned
        let owner = NSObject()
        let tree = ownedFocus(window: nil, listedByOwner: false)

        // then
        #expect(!Focus.focusIsInOwnedPane(tree.reader, owner: owner, region: Self.region))
    }

    @Test func givenNoPaneAboveTheFocusedElementOrNoFocusOrNoFrame_whenChecked_thenItIsNotOwned() {
        // given
        let owner = NSObject()
        let noPane = Tree()
        noPane.focused = noPane.node("Message", frame: Self.paneFrame)
        let none = Tree()
        let frameless = Tree()
        let pane = frameless.node("Task details", window: owner)
        frameless.focused = frameless.node("Notices", parent: pane)
        let empty = Tree()
        let emptyPane = empty.node("Task details", frame: .zero, window: owner)
        empty.focused = empty.node("Notices", parent: emptyPane)

        // then
        #expect(!Focus.focusIsInOwnedPane(noPane.reader, owner: owner, region: Self.region))
        #expect(!Focus.focusIsInOwnedPane(none.reader, owner: owner, region: Self.region))
        #expect(!Focus.focusIsInOwnedPane(frameless.reader, owner: owner, region: Self.region))
        #expect(!Focus.focusIsInOwnedPane(empty.reader, owner: owner, region: Self.region))
    }

    private final class Focusable: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func givenAHiddenParentAboveAnUnhiddenChipAndResponder_whenResolved_thenThereIsNoTarget() {
        // given the chip and its responder are unhidden themselves, but an ancestor outside the entry is hidden
        let parent = NSView()
        parent.isHidden = true
        let chip = NSView()
        chip.addSubview(Focusable())
        parent.addSubview(chip)

        // then
        #expect(!chip.isHidden && Focus.uniqueResponder(in: chip) == nil)
    }

    @Test func givenAHiddenContainerWithAnUnhiddenFocusableChild_whenResolved_thenThereIsNoTarget() {
        // given the child's own isHidden is false, but its container is hidden: it is not visible
        let chip = NSView()
        let container = NSView()
        container.isHidden = true
        container.addSubview(Focusable())
        chip.addSubview(container)

        // then
        #expect(Focus.uniqueResponder(in: chip) == nil)
    }

    @Test func givenAHiddenChipRoot_whenResolved_thenThereIsNoTarget() {
        // given
        let chip = Focusable()
        chip.isHidden = true

        // then
        #expect(Focus.uniqueResponder(in: chip) == nil)
    }

    @Test func givenAHiddenSiblingBesideTheOnlyVisibleResponder_whenResolved_thenTheVisibleOneIsTheTarget() {
        // given
        let chip = NSView()
        let hidden = NSView()
        hidden.isHidden = true
        hidden.addSubview(Focusable())
        let visible = Focusable()
        chip.addSubview(hidden)
        chip.addSubview(visible)

        // then
        #expect(Focus.uniqueResponder(in: chip) === visible)
    }

    // MARK: - Target (single responder)

    @Test func givenAChipView_whenOneDescendantAcceptsFocus_thenThatOneIsTheTarget() {
        // given
        let chip = NSView()
        let inner = NSView()
        let target = Focusable()
        chip.addSubview(inner)
        inner.addSubview(target)
        inner.addSubview(NSView())

        // then
        #expect(Focus.uniqueResponder(in: chip) === target)
    }

    @Test func givenTheChipViewItselfAcceptsFocus_whenNoDescendantDoes_thenItIsTheTarget() {
        // given
        let chip = Focusable()
        chip.addSubview(NSView())

        // then
        #expect(Focus.uniqueResponder(in: chip) === chip)
    }

    @Test func givenNoOrSeveralOrOnlyHiddenResponders_whenResolved_thenThereIsNoTarget() {
        // given
        let none = NSView()
        none.addSubview(NSView())
        let several = NSView()
        several.addSubview(Focusable())
        several.addSubview(Focusable())
        let hidden = NSView()
        let hiddenTarget = Focusable()
        hiddenTarget.isHidden = true
        hidden.addSubview(hiddenTarget)

        // then
        #expect(Focus.uniqueResponder(in: none) == nil)
        #expect(Focus.uniqueResponder(in: several) == nil, "an ambiguous item is not guessed at")
        #expect(Focus.uniqueResponder(in: hidden) == nil)
    }
}
