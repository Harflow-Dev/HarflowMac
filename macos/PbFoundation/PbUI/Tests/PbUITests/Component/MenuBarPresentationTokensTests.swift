import AppKit
@testable import PbUI
import SwiftUI
import Testing

// MARK: - MenuBarPresentationTokensTests

@MainActor @Suite struct MenuBarPresentationTokensTests {
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenShortcutHint_whenCompositedOnAccentFill_thenItMeetsTheMenuBarContrastFloor(
        appearance: NSAppearance.Name
    ) {
        // given
        let hint = Resolved.hex(Color.shortcutHint, in: appearance)
        let fill = Resolved.hex(Color.accentFill, in: appearance)

        // when
        let ratio = Contrast.ratio(hint, fill)

        // then
        #expect(ratio >= 4.5)
    }

    @Test func givenActivityCardBorderOverride_whenDefaultIsOmitted_thenTheSharedDefaultRemainsNamed() {
        // given / when
        let card = ActivityCard { Text("activity") }
        let mirror = Mirror(reflecting: card)
        let border = mirror.descendant("border") as? Color

        // then — nil is the compatibility contract; attention rows opt in explicitly.
        #expect(border == nil)
    }

    @Test func givenMonitorButtonStyle_whenHeightIsOmitted_thenItUsesTheExistingPrimaryHeight() {
        // given / when
        let style = MonitorButtonStyle()

        // then
        #expect(style.height == PbRadius.Metrics.primaryButtonHeight)
        #expect(style.height != PbRadius.Metrics.menuBarFooterButtonHeight)
    }
}
