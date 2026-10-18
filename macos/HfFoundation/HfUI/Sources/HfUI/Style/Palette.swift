import AppKit
import SwiftUI

public extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// An appearance-aware colour: `light` under Aqua, `dark` under Dark Aqua. A plain `Color(hex:)`
    /// is fixed, so it stays light while `.primary` text around it turns white in dark mode.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }

    static let hairline = Palette.hairline.color
    /// The accent as text or an icon: links, the running label.
    static let accentLink = Palette.accentLink.color
    /// Workflow selection marquee fill, preserving the accent ink's 8% opacity.
    static let workflowMarqueeFill = Palette.workflowMarqueeFill.color
    /// The accent as a fill behind `onAccent` content: the primary button, the send button.
    static let accentFill = Palette.accentFill.color
    /// Selected sidebar row fill.
    static let selectedRow = Palette.selectedRow.color
    static let doneGreen = Palette.doneGreen.color
    /// The done badge's tint.
    static let doneBG = Palette.doneBG.color
    static let failedRed = Palette.failedRed.color
    static let cancelledGray = Palette.cancelledGray.color
    static let runningBG = Palette.runningBG.color
    static let runningFG = Palette.runningFG.color
    /// Neutral card/chip fill (the install banner, a default `Chip`).
    static let neutralFill = Palette.neutralFill.color
    /// Text on `neutralFill`.
    static let neutralText = Palette.neutralText.color
    /// Caution foreground ("write_in_repo", "You're driving", the terminal marker).
    static let warningFG = Palette.warningFG.color
    static let warningBG = Palette.warningBG.color
    /// Danger foreground for the "publish"/"unrestricted" freedom chip.
    static let dangerFG = Palette.dangerFG.color
    static let dangerBG = Palette.dangerBG.color
    /// Fill behind monospaced blocks: fenced code, tool output, prompts.
    static let codeFill = Palette.codeFill.color
    static let editPreviewFill = Palette.editPreviewFill.color
    static let inspectorFill = Palette.inspectorFill.color
    static let diffHunkFill = Palette.diffHunkFill.color
    static let diffAddedFill = Palette.diffAddedFill.color
    static let diffRemovedFill = Palette.diffRemovedFill.color
    /// The detail pane's background.
    static let windowBG = Palette.windowBG.color
    /// Non-list sidebar chrome (headers, footer).
    static let sidebarBG = Palette.sidebarBG.color
    /// Fill of an `ActivityCard`.
    static let cardFill = Palette.cardFill.color
    /// Hairline border of an `ActivityCard`.
    static let cardBorder = Palette.cardBorder.color
    /// The message composer's field fill.
    static let composerFill = Palette.composerFill.color
    /// The tinted bubble behind a prompt.
    static let promptBubble = Palette.promptBubble.color
    /// Fill of small pills (file names).
    static let pillFill = Palette.pillFill.color
    /// The sliding segmented control's thumb, lifted off the `pillFill` track.
    static let selectedSegment = Palette.selectedSegment.color
    /// Secondary text (meta lines) with a contrast guaranteed on every surface above.
    static let secondaryText = Palette.secondaryText.color
    /// Unselected requested-access radio border, preserving the secondary ink's 60% opacity.
    static let accessRadioBorder = Palette.accessRadioBorder.color
    /// Tertiary text (section headers, timestamps, captions), lighter than `secondaryText`.
    static let tertiaryText = Palette.tertiaryText.color
    /// Primary text at full contrast: row and card titles read as content, not disabled chrome.
    static let primaryText = Palette.primaryText.color
    /// Text on an `accentFill` surface: white in both appearances.
    static let onAccent = Palette.onAccent.color
    /// The ⌘-key hint's ink on an `accentFill` button, composited once so its contrast floor
    /// stays the palette's to keep (77% white light / 90% dark over the accent fill).
    static let shortcutHint = Palette.shortcutHint.color
    /// The unfilled sidebar progress track on an emphasized native selection.
    static let sidebarSelectedProgressTrack = Palette.onAccent.color.opacity(0.25)
    /// Ink for the design's 1 pt elevation shadows, black in both appearances.
    static let shadow = Palette.shadow.color
    /// The pulsing dot beside a live step.
    static let liveDot = Palette.liveDot.color
    /// The recovery panel's floating border: the existing warning ink at its 30% border tone.
    static let recoveryBorder = Palette.recoveryBorder.color
    /// The needs-attention card's 35% warning border tone (§6.8).
    static let warningBorder = Palette.warningBorder.color
    /// Floating recovery panel elevation, preserving the black shadow's 12% opacity.
    static let recoveryShadow = Palette.recoveryShadow.color
}

// MARK: - Palette

/// Every colour the Monitor defines, with its light and dark value. The Phase 0 redesign
/// (docs/design/monitor-redesign/SPEC.md §3) is the source of these values; the one approved
/// deviation is `tertiaryText`/`cancelledGray` in dark mode, lightened from the spec's 0x8F8F98 to
/// 0x909099 so both clear 4.5:1 on `neutralFill`.
enum Palette {
    struct Entry {
        let name: String
        let light: UInt32
        let dark: UInt32
        let color: Color

        init(_ name: String, light: UInt32, dark: UInt32) {
            self.name = name
            self.light = light
            self.dark = dark
            self.color = Color(light: light, dark: dark)
        }

        /// An appearance-aware derived entry retaining its source RGB values and opacity.
        init(_ name: String, deriving source: Entry, opacity: Double) {
            self.name = name
            self.light = source.light
            self.dark = source.dark
            self.color = source.color.opacity(opacity)
        }
    }

    static let hairline = Entry("hairline", light: 0xE2E2E6, dark: 0x2E2E32)
    static let accentLink = Entry("accentLink", light: 0x3452CC, dark: 0x8EA2F0)
    /// The existing workflow selection marquee's faint accent fill.
    static let workflowMarqueeFill = Entry("workflowMarqueeFill", deriving: accentLink, opacity: 0.08)
    static let accentFill = Entry("accentFill", light: 0x3452CC, dark: 0x4A64D0)
    static let selectedRow = Entry("selectedRow", light: 0xE3E8F8, dark: 0x252C45)
    static let runningBG = Entry("runningBG", light: 0xE6EAF8, dark: 0x1F2640)
    static let runningFG = Entry("runningFG", light: 0x3452CC, dark: 0x8EA2F0)
    static let liveDot = Entry("liveDot", light: 0x3452CC, dark: 0x8EA2F0)
    static let doneGreen = Entry("doneGreen", light: 0x1B7A43, dark: 0x4BD08A)
    static let doneBG = Entry("doneBG", light: 0xE2F0E7, dark: 0x1D3326)
    static let warningFG = Entry("warningFG", light: 0x924D00, dark: 0xF2A93B)
    static let warningBG = Entry("warningBG", light: 0xF6EBDD, dark: 0x3A2C16)
    static let failedRed = Entry("failedRed", light: 0xBE2F29, dark: 0xFF6F66)
    static let dangerFG = Entry("dangerFG", light: 0xBE2F29, dark: 0xFF6F66)
    static let dangerBG = Entry("dangerBG", light: 0xF8E5E4, dark: 0x3D2120)
    static let cancelledGray = Entry("cancelledGray", light: 0x686870, dark: 0x909099)
    static let neutralFill = Entry("neutralFill", light: 0xECECEF, dark: 0x2A2A2E)
    static let neutralText = Entry("neutralText", light: 0x3A3A3C, dark: 0xD1D1D6)
    static let secondaryText = Entry("secondaryText", light: 0x4D4D55, dark: 0xB6B6BE)
    /// The existing unselected access radio ink, derived centrally without changing its RGB.
    static let accessRadioBorder = Entry("accessRadioBorder", deriving: secondaryText, opacity: 0.6)
    static let tertiaryText = Entry("tertiaryText", light: 0x686870, dark: 0x909099)
    static let primaryText = Entry("primaryText", light: 0x1C1C1F, dark: 0xF2F2F4)
    static let onAccent = Entry("onAccent", light: 0xFFFFFF, dark: 0xFFFFFF)
    /// The ⌘-key hint on an `accentFill` button (SPEC §6.8): white precomposited over the accent
    /// fill at 77% (light) / 90% (dark). The spec's own 75% white fails its §8 floor
    /// (4.42 light / 3.70 dark); these composites clear ≥ 4.5:1 on `accentFill` in both
    /// appearances — the plan's approved contrast deviation, kept in the palette so no view
    /// derives the tone locally.
    static let shortcutHint = Entry("shortcutHint", light: 0xD0D7F3, dark: 0xEDF0FA)
    static let shadow = Entry("shadow", light: 0x000000, dark: 0x000000)
    /// The recovery panel's border: the existing warning foreground at its 30% border tone,
    /// derived centrally so no view derives it locally and no RGB value changes.
    static let recoveryBorder = Entry("recoveryBorder", deriving: warningFG, opacity: 0.3)
    /// The needs-attention card's border: the warning foreground at its 35% border tone
    /// (SPEC §6.8), derived centrally so no view derives it locally and no RGB value changes.
    static let warningBorder = Entry("warningBorder", deriving: warningFG, opacity: 0.35)
    /// Opaque warning panel elevation ink, derived without changing the existing black RGB.
    static let recoveryShadow = Entry("recoveryShadow", deriving: shadow, opacity: 0.12)
    static let codeFill = Entry("codeFill", light: 0xECECEF, dark: 0x2A2A2E)
    static let editPreviewFill = Entry("editPreviewFill", light: 0xF8F8FA, dark: 0x262628)
    static let inspectorFill = Entry("inspectorFill", light: 0xF8F8FA, dark: 0x1A1A1D)
    static let diffHunkFill = Entry("diffHunkFill", light: 0xF0F4FA, dark: 0x25303F)
    static let diffAddedFill = Entry("diffAddedFill", light: 0xE2F0E7, dark: 0x1D3326)
    static let diffRemovedFill = Entry("diffRemovedFill", light: 0xF7E3E2, dark: 0x3A2120)
    static let claudeBG = Entry("claudeBG", light: 0xF6E3DA, dark: 0x4A2A1E)
    static let claudeFG = Entry("claudeFG", light: 0xA64B28, dark: 0xF2A07E)
    static let codexBG = Entry("codexBG", light: 0xE4E4E8, dark: 0x48484C)
    static let codexFG = Entry("codexFG", light: 0x1D1D1F, dark: 0xE8E8ED)
    static let opencodeBG = Entry("opencodeBG", light: 0xDDF0EE, dark: 0x16403C)
    static let opencodeFG = Entry("opencodeFG", light: 0x0F6B64, dark: 0x5FD3C7)
    static let vibeBG = Entry("vibeBG", light: 0xF1E6FA, dark: 0x3A2650)
    static let vibeFG = Entry("vibeFG", light: 0x6B2FA0, dark: 0xC99BF0)
    static let antigravityBG = Entry("antigravityBG", light: 0xF6E1EC, dark: 0x45213A)
    static let antigravityFG = Entry("antigravityFG", light: 0x8F2F5E, dark: 0xF4A6C9)
    static let otherBackendBG = Entry("otherBackendBG", light: 0xEEEEF0, dark: 0x3A3A3C)
    static let otherBackendFG = Entry("otherBackendFG", light: 0x3A3A3C, dark: 0xD1D1D6)

    static let windowBG = Entry("windowBG", light: 0xF3F3F5, dark: 0x161618)
    static let sidebarBG = Entry("sidebarBG", light: 0xFBFBFC, dark: 0x2A2A2E)
    static let cardFill = Entry("cardFill", light: 0xFFFFFF, dark: 0x202023)
    static let cardBorder = Entry("cardBorder", light: 0xE2E2E6, dark: 0x2E2E32)
    static let composerFill = Entry("composerFill", light: 0xFFFFFF, dark: 0x252528)
    static let promptBubble = Entry("promptBubble", light: 0xE6EAF8, dark: 0x1F2640)
    static let pillFill = Entry("pillFill", light: 0xECECEF, dark: 0x2A2A2E)
    static let selectedSegment = Entry("selectedSegment", light: 0xFFFFFF, dark: 0x3A3A3F)
    static let dotClaude = Entry("dot.claude", light: 0xC96442, dark: 0xE08A66)
    static let dotCodex = Entry("dot.codex", light: 0x6B6B75, dark: 0xA3A3AD)
    static let dotVibe = Entry("dot.vibe", light: 0x7A4FE0, dark: 0xA68BFA)
    static let dotAntigravity = Entry("dot.antigravity", light: 0xB4417A, dark: 0xF08AB8)
    static let dotOpencode = Entry("dot.opencode", light: 0x0B8A7C, dark: 0x2CC2B0)
    static let dotOther = Entry("dot.other", light: 0x8E8E93, dark: 0x98989D)

    static let all: [Entry] = [
        hairline, accentLink, workflowMarqueeFill, accentFill, selectedRow, runningBG, runningFG, liveDot, doneGreen,
        doneBG, warningFG, warningBG, failedRed, dangerFG, dangerBG, cancelledGray, neutralFill,
        neutralText, secondaryText, accessRadioBorder, tertiaryText, primaryText, onAccent, shortcutHint, shadow,
        recoveryBorder, recoveryShadow, warningBorder, codeFill,
        editPreviewFill, inspectorFill, diffHunkFill, diffAddedFill, diffRemovedFill, claudeBG,
        claudeFG, codexBG, codexFG, opencodeBG, opencodeFG, vibeBG, vibeFG, antigravityBG,
        antigravityFG, otherBackendBG, otherBackendFG,
        windowBG, sidebarBG, cardFill, cardBorder, composerFill, promptBubble, pillFill,
        selectedSegment, dotClaude, dotCodex, dotVibe, dotAntigravity, dotOpencode, dotOther
    ]
}
