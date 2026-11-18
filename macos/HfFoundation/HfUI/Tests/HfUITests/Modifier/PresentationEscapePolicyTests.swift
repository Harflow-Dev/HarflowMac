import AppKit
import HfCommon
@testable import HfUI
import SwiftUI
import Testing

// MARK: - PresentationEscapePolicyTests

@MainActor @Suite struct PresentationEscapePolicyTests {
    private func content(defaultRole: ButtonRole?, hasDefault: Bool = true) -> AlertContent {
        AlertContent(title: "Title") {
            AlertAction(title: "Confirm", role: .destructive)
            AlertAction(title: "Cancel", role: defaultRole, isDefault: hasDefault)
        }
    }

    private func situation(_ edit: (inout PresentationEscapePolicy.Situation) -> Void = { _ in }) -> PresentationEscapePolicy.Situation {
        var base = PresentationEscapePolicy.Situation(
            keyCode: 53, isRepeat: false, modifiers: [], eventIsRecordedSheet: true, sheetIsAttached: true,
            sheetHasNestedSheet: false, defaultButtonTitleMatches: true, alreadyConsumed: false)
        edit(&base)
        return base
    }

    @Test func givenAlertOrDialogWithCancelDefault_whenAskedForEligibility_thenItsDefaultTitleIsReturned() {
        // given
        let cancelDefault = content(defaultRole: .cancel)
        // when / then
        #expect(PresentationEscapePolicy.cancelDefaultTitle(for: .alert(cancelDefault)) == "Cancel")
        #expect(PresentationEscapePolicy.cancelDefaultTitle(for: .dialog(cancelDefault)) == "Cancel")
    }

    @Test func givenDefaultWithoutCancelRoleOrNoDefaultOrOtherEvent_whenAskedForEligibility_thenNothingIsEligible() {
        // given
        let plainDefault = content(defaultRole: nil)
        let destructiveDefault = content(defaultRole: .destructive)
        let noDefault = content(defaultRole: .cancel, hasDefault: false)
        // when / then
        #expect(PresentationEscapePolicy.eligibleContent(for: .alert(plainDefault)) == nil)
        #expect(PresentationEscapePolicy.eligibleContent(for: .dialog(destructiveDefault)) == nil)
        #expect(PresentationEscapePolicy.eligibleContent(for: .dialog(noDefault)) == nil)
        #expect(PresentationEscapePolicy.eligibleContent(for: .none) == nil)
        #expect(PresentationEscapePolicy.eligibleContent(for: .incident(source: "s", message: "m")) == nil)
    }

    @Test func givenPlainEscapeOnRecordedSheet_whenDeciding_thenItIsConsumedAndClicked() {
        #expect(PresentationEscapePolicy.decide(situation()) == .consumeAndClick)
    }

    @Test func givenEscapeAlreadyConsumedForThisPresentation_whenDeciding_thenItIsConsumedWithoutActing() {
        #expect(PresentationEscapePolicy.decide(situation { $0.alreadyConsumed = true }) == .consumeOnly)
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .option, .control, .shift])
    func givenModifiedEscape_whenDeciding_thenItPasses(_ modifier: NSEvent.ModifierFlags) {
        #expect(PresentationEscapePolicy.decide(situation { $0.modifiers = modifier }) == .pass)
    }

    @Test func givenCapsLockOnly_whenDeciding_thenEscapeIsStillOurs() {
        #expect(PresentationEscapePolicy.decide(situation { $0.modifiers = .capsLock }) == .consumeAndClick)
    }

    @Test func givenOtherKeyOrRepeat_whenDeciding_thenItPasses() {
        #expect(PresentationEscapePolicy.decide(situation { $0.keyCode = 36 }) == .pass)
        #expect(PresentationEscapePolicy.decide(situation { $0.isRepeat = true }) == .pass)
    }

    @Test func givenSheetNotOwnedOrDetachedOrNested_whenDeciding_thenItPasses() {
        #expect(PresentationEscapePolicy.decide(situation { $0.eventIsRecordedSheet = false }) == .pass)
        #expect(PresentationEscapePolicy.decide(situation { $0.sheetIsAttached = false }) == .pass)
        #expect(PresentationEscapePolicy.decide(situation { $0.sheetHasNestedSheet = true }) == .pass)
        #expect(PresentationEscapePolicy.decide(situation { $0.sheetHasNestedSheet = true; $0.alreadyConsumed = true }) == .pass)
    }

    @Test func givenDefaultButtonTitleDiffers_whenDeciding_thenItPasses() {
        #expect(PresentationEscapePolicy.decide(situation { $0.defaultButtonTitleMatches = false }) == .pass)
    }

    @Test func givenNoSheetBeganMark_whenEscapeArrives_thenAdoptionIsRefused() {
        #expect(!PresentationEscapePolicy.mayAdoptAtKeyTime(sheetBegan: false, isHostAttachedSheet: true))
        #expect(!PresentationEscapePolicy.mayAdoptAtKeyTime(sheetBegan: true, isHostAttachedSheet: false))
        #expect(PresentationEscapePolicy.mayAdoptAtKeyTime(sheetBegan: true, isHostAttachedSheet: true))
    }
}
