import AppKit
@testable import PbUI
import SwiftUI
import Testing

// MARK: - PaletteTests

@Suite struct PaletteTests {

    /// The complete expected palette: SPEC §3's values plus the approved additions
    /// (`accentFill`, `doneBG`, `tertiaryText`, `primaryText`, `onAccent`, `shadow`) and the
    /// approved dark-mode correction — `tertiaryText`/`cancelledGray` lightened from the spec's
    /// 0x8F8F98 to 0x909099 so both clear 4.5:1 on `neutralFill`. Entries the redesign does not
    /// re-specify (`neutralText`, `editPreviewFill`, `diffHunkFill`, `composerFill`, the backend
    /// chip pairs) keep their existing values, pinned here like the rest.
    private static let expected: [(name: String, light: UInt32, dark: UInt32)] = [
        ("hairline", 0xE2E2E6, 0x2E2E32),
        ("accentLink", 0x3452CC, 0x8EA2F0),
        ("workflowMarqueeFill", 0x3452CC, 0x8EA2F0),
        ("accentFill", 0x3452CC, 0x4A64D0),
        ("selectedRow", 0xE3E8F8, 0x252C45),
        ("runningBG", 0xE6EAF8, 0x1F2640),
        ("runningFG", 0x3452CC, 0x8EA2F0),
        ("liveDot", 0x3452CC, 0x8EA2F0),
        ("doneGreen", 0x1B7A43, 0x4BD08A),
        ("doneBG", 0xE2F0E7, 0x1D3326),
        ("warningFG", 0x924D00, 0xF2A93B),
        ("warningBG", 0xF6EBDD, 0x3A2C16),
        ("recoveryBorder", 0x924D00, 0xF2A93B),
        ("recoveryShadow", 0x000000, 0x000000),
        ("failedRed", 0xBE2F29, 0xFF6F66),
        ("dangerFG", 0xBE2F29, 0xFF6F66),
        ("dangerBG", 0xF8E5E4, 0x3D2120),
        ("cancelledGray", 0x686870, 0x909099),
        ("neutralFill", 0xECECEF, 0x2A2A2E),
        ("neutralText", 0x3A3A3C, 0xD1D1D6),
        ("secondaryText", 0x4D4D55, 0xB6B6BE),
        ("accessRadioBorder", 0x4D4D55, 0xB6B6BE),
        ("tertiaryText", 0x686870, 0x909099),
        ("primaryText", 0x1C1C1F, 0xF2F2F4),
        ("onAccent", 0xFFFFFF, 0xFFFFFF),
        ("shortcutHint", 0xD0D7F3, 0xEDF0FA),
        ("shadow", 0x000000, 0x000000),
        ("codeFill", 0xECECEF, 0x2A2A2E),
        ("editPreviewFill", 0xF8F8FA, 0x262628),
        ("inspectorFill", 0xF8F8FA, 0x1A1A1D),
        ("diffHunkFill", 0xF0F4FA, 0x25303F),
        ("diffAddedFill", 0xE2F0E7, 0x1D3326),
        ("diffRemovedFill", 0xF7E3E2, 0x3A2120),
        ("claudeBG", 0xF6E3DA, 0x4A2A1E),
        ("claudeFG", 0xA64B28, 0xF2A07E),
        ("codexBG", 0xE4E4E8, 0x48484C),
        ("codexFG", 0x1D1D1F, 0xE8E8ED),
        ("opencodeBG", 0xDDF0EE, 0x16403C),
        ("opencodeFG", 0x0F6B64, 0x5FD3C7),
        ("vibeBG", 0xF1E6FA, 0x3A2650),
        ("vibeFG", 0x6B2FA0, 0xC99BF0),
        ("antigravityBG", 0xF6E1EC, 0x45213A),
        ("antigravityFG", 0x8F2F5E, 0xF4A6C9),
        ("otherBackendBG", 0xEEEEF0, 0x3A3A3C),
        ("otherBackendFG", 0x3A3A3C, 0xD1D1D6),
        ("warningBorder", 0x924D00, 0xF2A93B),
        ("windowBG", 0xF3F3F5, 0x161618),
        ("sidebarBG", 0xFBFBFC, 0x2A2A2E),
        ("cardFill", 0xFFFFFF, 0x202023),
        ("cardBorder", 0xE2E2E6, 0x2E2E32),
        ("composerFill", 0xFFFFFF, 0x252528),
        ("promptBubble", 0xE6EAF8, 0x1F2640),
        ("pillFill", 0xECECEF, 0x2A2A2E),
        ("selectedSegment", 0xFFFFFF, 0x3A3A3F),
        ("dot.claude", 0xC96442, 0xE08A66),
        ("dot.codex", 0x6B6B75, 0xA3A3AD),
        ("dot.vibe", 0x7A4FE0, 0xA68BFA),
        ("dot.antigravity", 0xB4417A, 0xF08AB8),
        ("dot.opencode", 0x0B8A7C, 0x2CC2B0),
        ("dot.other", 0x8E8E93, 0x98989D)
    ]

    /// Entries whose role fixes one value in both appearances (`onAccent`, `shadow`); every other
    /// entry must resolve differently per appearance.
    private static let fixedInBothModes: Set<String> = ["onAccent", "shadow", "recoveryShadow"]

    @Test func givenEachPaletteEntry_whenResolvedInEachAppearance_thenItMatchesItsSpecifiedValue() throws {
        for expected in Self.expected {
            // given
            let entry = try #require(Palette.all.first { $0.name == expected.name }, "\(expected.name) missing from Palette.all")

            // when
            let light = Resolved.hex(entry.color, in: .aqua)
            let dark = Resolved.hex(entry.color, in: .darkAqua)

            // then — the exact SPEC §3 value (or approved addition/correction), per appearance.
            #expect(light == expected.light, "\(expected.name) light: \(String(light, radix: 16))")
            #expect(dark == expected.dark, "\(expected.name) dark: \(String(dark, radix: 16))")
        }
    }

    @Test func givenPaletteAll_whenCheckedForCompleteness_thenItCarriesEveryEntryExactlyOnce() {
        // given
        let names = Palette.all.map(\.name)

        // when / then — exhaustive: no entry lost by a rename, none duplicated.
        #expect(names.count == Set(names).count, "Palette.all contains duplicate names")
        #expect(names.count == Self.expected.count, "Palette.all carries \(names.count) entries, expected \(Self.expected.count)")
        for expected in Self.expected {
            #expect(names.filter { $0 == expected.name }.count == 1, "\(expected.name) must appear exactly once in Palette.all")
        }
    }

    @Test func givenEachEntryThatVariesByAppearance_whenResolvedInBoth_thenLightAndDarkDiffer() {
        for entry in Palette.all where !Self.fixedInBothModes.contains(entry.name) {
            // given / when
            let light = Resolved.hex(entry.color, in: .aqua)
            let dark = Resolved.hex(entry.color, in: .darkAqua)

            // then — a dark variant exists; the two fixed semantic entries are exempt.
            #expect(dark != light, "\(entry.name) has no dark variant")
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenTheDerivedAccessRadioBorder_whenResolved_thenItPreservesSourceRGBAndUsesTheNamedOpacity(appearance: NSAppearance.Name) {
        // given / when
        var resolved: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = NSColor(Palette.accessRadioBorder.color).usingColorSpace(.sRGB)
        }

        // then — opacity is the only derived change; RGB remains the secondary-text token for each
        // appearance, so the existing radio ink does not acquire a new hard-coded colour.
        let color = resolved!
        let expectedRGB = appearance == .darkAqua ? Palette.secondaryText.dark : Palette.secondaryText.light
        #expect(Resolved.hex(Palette.accessRadioBorder.color, in: appearance) == expectedRGB)
        #expect(abs(color.alphaComponent - 0.6) < 0.01)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenTheDerivedWorkflowMarqueeFill_whenResolved_thenItPreservesAccentRGBAndUsesEightPercentAlpha(appearance: NSAppearance.Name) {
        var resolved: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = NSColor(Palette.workflowMarqueeFill.color).usingColorSpace(.sRGB)
        }
        let color = resolved!
        let expectedRGB = appearance == .darkAqua ? Palette.accentLink.dark : Palette.accentLink.light
        #expect(Resolved.hex(Palette.workflowMarqueeFill.color, in: appearance) == expectedRGB)
        #expect(abs(color.alphaComponent - 0.08) < 0.01)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenTheDerivedRecoveryBorder_whenResolved_thenItPreservesWarningRGBAndUsesThirtyPercentAlpha(appearance: NSAppearance.Name) {
        var resolved: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = NSColor(Palette.recoveryBorder.color).usingColorSpace(.sRGB)
        }
        let color = resolved!
        let expectedRGB = appearance == .darkAqua ? Palette.warningFG.dark : Palette.warningFG.light
        #expect(Resolved.hex(Palette.recoveryBorder.color, in: appearance) == expectedRGB)
        #expect(abs(color.alphaComponent - 0.3) < 0.01)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenTheDerivedRecoveryShadow_whenResolved_thenItPreservesBlackRGBAndUsesTwelvePercentAlpha(appearance: NSAppearance.Name) {
        var resolved: NSColor?
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            resolved = NSColor(Palette.recoveryShadow.color).usingColorSpace(.sRGB)
        }
        let color = resolved!
        #expect(Resolved.hex(Palette.recoveryShadow.color, in: appearance) == 0)
        #expect(abs(color.alphaComponent - 0.12) < 0.01)
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenRecoveryTextOnWarningBackground_whenResolved_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        // The recovery panel uses these existing semantic foreground tokens on opaque warningBG.
        let background = Resolved.hex(Color.warningBG, in: appearance)
        for (name, foreground) in [("primary", Color.primaryText), ("secondary", Color.secondaryText),
                                   ("warning", Color.warningFG)] {
            let ratio = Contrast.ratio(Resolved.hex(foreground, in: appearance), background)
            #expect(ratio >= 4.5, "\(name) on warningBG in \(appearance.rawValue): \(ratio)")
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenPrimaryText_whenDrawnOnEachPaletteSurface_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        let surfaces: [(String, Color)] = [
            ("windowBG", .windowBG), ("cardFill", .cardFill), ("neutralFill", .neutralFill)
        ]
        for (name, surface) in surfaces {
            // given
            let text = Resolved.hex(Color.primaryText, in: appearance)

            // when
            let ratio = Contrast.ratio(text, Resolved.hex(surface, in: appearance))

            // then
            #expect(ratio >= 4.5, "primaryText on \(name) in \(appearance.rawValue): \(ratio)")
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenSystemLabelText_whenDrawnOnEachPaletteSurface_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        let surfaces: [(String, Color)] = [
            ("neutralFill", .neutralFill), ("selectedRow", .selectedRow), ("codeFill", .codeFill),
            ("editPreviewFill", .editPreviewFill), ("inspectorFill", .inspectorFill), ("diffHunkFill", .diffHunkFill),
            ("diffAddedFill", .diffAddedFill), ("diffRemovedFill", .diffRemovedFill), ("runningBG", .runningBG),
            ("windowBG", .windowBG), ("cardFill", .cardFill), ("composerFill", .composerFill),
            ("promptBubble", .promptBubble), ("pillFill", .pillFill), ("sidebarBG", .sidebarBG)
        ]
        for (name, surface) in surfaces {
            // given
            let text = Resolved.hex(Color(nsColor: .labelColor), in: appearance)

            // when
            let ratio = Contrast.ratio(text, Resolved.hex(surface, in: appearance))

            // then
            #expect(ratio >= 4.5, "label on \(name) in \(appearance.rawValue): \(ratio)")
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenSecondaryAndTertiaryText_whenDrawnOnTheirSurfaces_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        // The SPEC §3 requirement: both text tiers hold 4.5:1 on windowBG, cardFill and neutralFill.
        // tertiaryText's dark value is the approved 0x909099 correction, measured against exactly
        // these surfaces (4.52:1 on neutralFill — the value the user approved for this reason).
        let texts: [(String, Color)] = [("secondaryText", .secondaryText), ("tertiaryText", .tertiaryText)]
        let surfaces: [(String, Color)] = [
            ("windowBG", .windowBG), ("cardFill", .cardFill), ("neutralFill", .neutralFill), ("sidebarBG", .sidebarBG),
            ("inspectorFill", .inspectorFill)
        ]
        for (textName, text) in texts {
            for (surfaceName, surface) in surfaces {
                // given
                let foreground = Resolved.hex(text, in: appearance)

                // when
                let ratio = Contrast.ratio(foreground, Resolved.hex(surface, in: appearance))

                // then
                #expect(ratio >= 4.5, "\(textName) on \(surfaceName) in \(appearance.rawValue): \(ratio)")
            }
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenEachStatusForeground_whenDrawnOnTheRedesignedContentSurfaces_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        // Status colours are drawn on the palette's content surfaces (the detail pane's windowBG,
        // cards, grouped rows) — the redesign pins them there, replacing the old system-content
        // background assertion.
        let surfaces: [(String, Color)] = [
            ("windowBG", .windowBG), ("cardFill", .cardFill), ("neutralFill", .neutralFill)
        ]
        for (name, foreground) in Self.statusForegrounds {
            for (surfaceName, surface) in surfaces {
                // given
                let foreground = Resolved.hex(foreground, in: appearance)

                // when
                let ratio = Contrast.ratio(foreground, Resolved.hex(surface, in: appearance))

                // then
                #expect(ratio >= 4.5, "\(name) on \(surfaceName) in \(appearance.rawValue): \(ratio)")
            }
        }
    }

    /// The one production surface that is a system colour rather than a palette token: the
    /// workflow canvas split draws on `NSColor.windowBackgroundColor`, so the status foregrounds
    /// must still hold there — including the approved 0x909099 `cancelledGray` correction.
    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenEachStatusForeground_whenDrawnOnTheSystemWindowBackground_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        for (name, foreground) in Self.statusForegrounds {
            // given
            let window = Resolved.hex(Color(nsColor: .windowBackgroundColor), in: appearance)

            // when
            let ratio = Contrast.ratio(Resolved.hex(foreground, in: appearance), window)

            // then
            #expect(ratio >= 4.5, "\(name) on the window background in \(appearance.rawValue): \(ratio)")
        }
    }

    private static let statusForegrounds: [(String, Color)] = [
        ("doneGreen", .doneGreen), ("failedRed", .failedRed), ("cancelledGray", .cancelledGray),
        ("accentLink", .accentLink), ("runningFG", .runningFG), ("warningFG", .warningFG)
    ]

    @Test func givenEachBackendDot_whenResolvedInBothModes_thenLightAndDarkValuesDiffer() {
        // given
        let dots = [Palette.dotClaude, Palette.dotCodex, Palette.dotVibe, Palette.dotOpencode, Palette.dotAntigravity, Palette.dotOther]

        // when / then — antigravity is magenta now (0xB4417A/0xF08AB8), so no agent dot shares
        // the accent hue; each dot still carries a dark variant and sits in `Palette.all`.
        for dot in dots {
            #expect(dot.light != dot.dark, "\(dot.name) has identical light and dark values")
            #expect(Palette.all.contains { $0.name == dot.name }, "\(dot.name) missing from Palette.all")
        }
        let accentHues = [Palette.accentLink.light, Palette.accentLink.dark]
        for dot in dots {
            #expect(!accentHues.contains(dot.light), "\(dot.name) light shares the accent value")
            #expect(!accentHues.contains(dot.dark), "\(dot.name) dark shares the accent value")
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenEachForegroundAndItsFill_whenDrawnTogether_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        var pairs: [(String, Color, Color)] = BackendStyle.known.map { backend in
            let (background, foreground) = BackendStyle.colors(backend)
            return (backend, foreground, background)
        }
        let (neutralBackground, neutralForeground) = BackendStyle.colors("unknown-backend")
        pairs += [
            ("unknown backend", neutralForeground, neutralBackground),
            ("chip", .neutralText, .neutralFill),
            ("warning", .warningFG, .warningBG),
            ("running", .runningFG, .runningBG),
            ("danger", .dangerFG, .dangerBG),
            ("failedRed on banner", .failedRed, .neutralFill),
            ("doneGreen in edit preview", .doneGreen, .editPreviewFill),
            ("failedRed in edit preview", .failedRed, .editPreviewFill),
            // The badge and button fills the redesign adds (SPEC §5.1/§5.3).
            ("done badge", .doneGreen, .doneBG),
            ("failed badge", .failedRed, .dangerBG),
            ("cancelled badge", .cancelledGray, .neutralFill),
            ("settling badge", .runningFG, .runningBG),
            ("primary button", .onAccent, .accentFill),
            ("tinted button", .accentLink, .runningBG),
            ("destructive button", .dangerFG, .dangerBG)
        ]
        for (name, foreground, background) in pairs {
            // given
            let text = Resolved.hex(foreground, in: appearance)

            // when
            let ratio = Contrast.ratio(text, Resolved.hex(background, in: appearance))

            // then
            #expect(ratio >= 4.5, "\(name) in \(appearance.rawValue): \(ratio)")
        }
    }

    @Test func givenTheHairline_whenResolvedInDarkAqua_thenIsDarkerThanTheLightHairline() {
        // given / when
        let light = Contrast.luminance(Resolved.hex(.hairline, in: .aqua))
        let dark = Contrast.luminance(Resolved.hex(.hairline, in: .darkAqua))

        // then — a light-grey rule on a dark window reads as a bright stripe, not a hairline.
        #expect(dark < light)
    }
}

// MARK: - Resolved

enum Resolved {
    /// The 0xRRGGBB value `color` draws with under `appearance`.
    static func hex(_ color: Color, in appearance: NSAppearance.Name) -> UInt32 {
        var result: UInt32 = 0
        NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
            let rgb = NSColor(color).usingColorSpace(.sRGB)!
            let channel = { (value: CGFloat) in UInt32((min(max(value, 0), 1) * 255).rounded()) }
            result = channel(rgb.redComponent) << 16 | channel(rgb.greenComponent) << 8 | channel(rgb.blueComponent)
        }
        return result
    }
}

// MARK: - Contrast

/// WCAG 2 relative luminance and contrast ratio.
enum Contrast {
    static func luminance(_ hex: UInt32) -> Double {
        let channels = [16, 8, 0].map { Double((hex >> UInt32($0)) & 0xFF) / 255 }
        let linear = channels.map { $0 <= 0.039_28 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]
    }

    static func ratio(_ first: UInt32, _ second: UInt32) -> Double {
        let (lighter, darker) = (max(luminance(first), luminance(second)), min(luminance(first), luminance(second)))
        return (lighter + 0.05) / (darker + 0.05)
    }
}
