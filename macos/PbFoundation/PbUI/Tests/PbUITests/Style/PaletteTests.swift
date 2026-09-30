import AppKit
@testable import PbUI
import SwiftUI
import Testing

// MARK: - PaletteTests

@Suite struct PaletteTests {

    @Test func givenEveryPaletteColor_whenResolvedInAqua_thenKeepsItsOriginalLightValue() {
        for entry in Palette.all {
            // given
            let color = entry.color

            // when
            let light = Resolved.hex(color, in: .aqua)

            // then — light mode is unchanged by the dark-mode work.
            #expect(light == entry.light, "\(entry.name) light")
        }
    }

    @Test func givenEveryPaletteColor_whenResolvedInDarkAqua_thenUsesItsDarkValue() {
        for entry in Palette.all {
            // given
            let color = entry.color

            // when
            let dark = Resolved.hex(color, in: .darkAqua)

            // then
            #expect(dark == entry.dark, "\(entry.name) dark")
            #expect(dark != entry.light, "\(entry.name) has no dark variant")
        }
    }

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenPrimaryText_whenDrawnOnEachPaletteSurface_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
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
    func givenSecondaryText_whenDrawnOnEachNewSurface_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        let surfaces: [(String, Color)] = [
            ("windowBG", .windowBG), ("sidebarBG", .sidebarBG), ("cardFill", .cardFill), ("composerFill", .composerFill),
            ("promptBubble", .promptBubble), ("pillFill", .pillFill), ("inspectorFill", .inspectorFill)
        ]
        for (name, surface) in surfaces {
            // given
            let text = Resolved.hex(.secondaryText, in: appearance)

            // when
            let ratio = Contrast.ratio(text, Resolved.hex(surface, in: appearance))

            // then
            #expect(ratio >= 4.5, "secondaryText on \(name) in \(appearance.rawValue): \(ratio)")
        }
    }

    @Test func givenEachBackendDot_whenResolvedInBothModes_thenLightAndDarkValuesDiffer() {
        // given
        let dots = [Palette.dotClaude, Palette.dotCodex, Palette.dotVibe, Palette.dotOpencode, Palette.dotOther]

        // when / then
        for dot in dots {
            #expect(dot.light != dot.dark, "\(dot.name) has identical light and dark values")
            #expect(Palette.all.contains { $0.name == dot.name }, "\(dot.name) missing from Palette.all")
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
            ("failedRed in edit preview", .failedRed, .editPreviewFill)
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

    @Test(arguments: [NSAppearance.Name.aqua, .darkAqua])
    func givenEachStatusForeground_whenDrawnOnTheContentBackground_thenMeetsReadableContrast(appearance: NSAppearance.Name) {
        for (name, foreground) in Self.statusForegrounds {
            // given
            let content = Resolved.hex(Color(nsColor: .controlBackgroundColor), in: appearance)

            // when
            let ratio = Contrast.ratio(Resolved.hex(foreground, in: appearance), content)

            // then
            #expect(ratio >= 4.5, "\(name) on content in \(appearance.rawValue): \(ratio)")
        }
    }

    /// Dark Aqua only: the light values are the app's originals, designed against white content,
    /// and are out of scope here; the dark values are new and must hold on the grey window too.
    @Test func givenEachStatusForeground_whenDrawnOnTheDarkWindowBackground_thenMeetsReadableContrast() {
        for (name, foreground) in Self.statusForegrounds {
            // given
            let window = Resolved.hex(Color(nsColor: .windowBackgroundColor), in: .darkAqua)

            // when
            let ratio = Contrast.ratio(Resolved.hex(foreground, in: .darkAqua), window)

            // then
            #expect(ratio >= 4.5, "\(name) on dark window: \(ratio)")
        }
    }

    private static let statusForegrounds: [(String, Color)] = [
        ("doneGreen", .doneGreen), ("failedRed", .failedRed), ("cancelledGray", .cancelledGray),
        ("accentLink", .accentLink), ("runningFG", .runningFG), ("warningFG", .warningFG)
    ]

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
