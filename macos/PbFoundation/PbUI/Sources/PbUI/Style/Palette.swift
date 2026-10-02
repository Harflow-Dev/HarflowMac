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
    static let accentLink = Palette.accentLink.color
    /// Selected sidebar row fill.
    static let selectedRow = Palette.selectedRow.color
    static let doneGreen = Palette.doneGreen.color
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
    /// Secondary text with a contrast guaranteed on every surface above.
    static let secondaryText = Palette.secondaryText.color
    /// The pulsing dot beside a live step.
    static let liveDot = Palette.liveDot.color
}

// MARK: - Palette

/// Every colour the Monitor defines, with its light and dark value. Light values are the app's
/// original ones; dark values keep the same role with readable contrast on a dark window.
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
    }

    static let hairline = Entry("hairline", light: 0xE6E5EA, dark: 0x3A3A3C)
    static let accentLink = Entry("accentLink", light: 0x0A63CE, dark: 0x5AA5FF)
    static let selectedRow = Entry("selectedRow", light: 0xDCE8F8, dark: 0x25344A)
    static let doneGreen = Entry("doneGreen", light: 0x1B7F3B, dark: 0x3FC06A)
    static let failedRed = Entry("failedRed", light: 0xC4312B, dark: 0xFF8279)
    static let cancelledGray = Entry("cancelledGray", light: 0x6E6E76, dark: 0x9A9AA2)
    static let runningBG = Entry("runningBG", light: 0xE7EFFA, dark: 0x1C2D44)
    static let runningFG = Entry("runningFG", light: 0x0A63CE, dark: 0x7FB2FF)
    static let neutralFill = Entry("neutralFill", light: 0xF2F2F5, dark: 0x3A3A3C)
    static let neutralText = Entry("neutralText", light: 0x3A3A3C, dark: 0xD1D1D6)
    static let warningFG = Entry("warningFG", light: 0x8A4B00, dark: 0xF5B35A)
    static let warningBG = Entry("warningBG", light: 0xFDF0DC, dark: 0x4A3514)
    static let dangerFG = Entry("dangerFG", light: 0x9B2A23, dark: 0xFF8A80)
    static let dangerBG = Entry("dangerBG", light: 0xFBE4E2, dark: 0x4E2220)
    static let codeFill = Entry("codeFill", light: 0xF5F5F7, dark: 0x2C2C2E)
    static let editPreviewFill = Entry("editPreviewFill", light: 0xF8F8FA, dark: 0x262628)
    static let inspectorFill = Entry("inspectorFill", light: 0xF7F7F9, dark: 0x1B1B1D)
    static let diffHunkFill = Entry("diffHunkFill", light: 0xF0F4FA, dark: 0x25303F)
    static let diffAddedFill = Entry("diffAddedFill", light: 0xE6F4EA, dark: 0x1F3A27)
    static let diffRemovedFill = Entry("diffRemovedFill", light: 0xFCE8E6, dark: 0x45211F)
    static let claudeBG = Entry("claudeBG", light: 0xF6E3DA, dark: 0x4A2A1E)
    static let claudeFG = Entry("claudeFG", light: 0xA64B28, dark: 0xF2A07E)
    static let codexBG = Entry("codexBG", light: 0xE4E4E8, dark: 0x48484C)
    static let codexFG = Entry("codexFG", light: 0x1D1D1F, dark: 0xE8E8ED)
    static let opencodeBG = Entry("opencodeBG", light: 0xDDF0EE, dark: 0x16403C)
    static let opencodeFG = Entry("opencodeFG", light: 0x0F6B64, dark: 0x5FD3C7)
    static let vibeBG = Entry("vibeBG", light: 0xF1E6FA, dark: 0x3A2650)
    static let vibeFG = Entry("vibeFG", light: 0x6B2FA0, dark: 0xC99BF0)
    static let antigravityBG = Entry("antigravityBG", light: 0xD9E8FB, dark: 0x1E3048)
    static let antigravityFG = Entry("antigravityFG", light: 0x1A4E8F, dark: 0x7FAEF0)
    static let otherBackendBG = Entry("otherBackendBG", light: 0xEEEEF0, dark: 0x3A3A3C)
    static let otherBackendFG = Entry("otherBackendFG", light: 0x3A3A3C, dark: 0xD1D1D6)

    static let windowBG = Entry("windowBG", light: 0xFFFFFF, dark: 0x1E1E20)
    static let sidebarBG = Entry("sidebarBG", light: 0xF4F4F6, dark: 0x19191B)
    static let cardFill = Entry("cardFill", light: 0xFAFAFB, dark: 0x232326)
    static let cardBorder = Entry("cardBorder", light: 0xE3E3E7, dark: 0x333336)
    static let composerFill = Entry("composerFill", light: 0xFFFFFF, dark: 0x252528)
    static let promptBubble = Entry("promptBubble", light: 0xEAF1FB, dark: 0x1F2A3A)
    static let pillFill = Entry("pillFill", light: 0xF0F0F2, dark: 0x2B2B2E)
    static let selectedSegment = Entry("selectedSegment", light: 0xFFFFFF, dark: 0x4A4A4E)
    static let secondaryText = Entry("secondaryText", light: 0x6B6B73, dark: 0x9A9AA2)
    static let liveDot = Entry("liveDot", light: 0x2F7BF0, dark: 0x5B9CFF)
    static let dotClaude = Entry("dot.claude", light: 0xC8643C, dark: 0xE08A62)
    static let dotCodex = Entry("dot.codex", light: 0x6E6E76, dark: 0xC9C9CF)
    static let dotVibe = Entry("dot.vibe", light: 0x8A4FD0, dark: 0xB48CF0)
    static let dotAntigravity = Entry("dot.antigravity", light: 0x2E6FD8, dark: 0x7FAEF0)
    static let dotOpencode = Entry("dot.opencode", light: 0x0F6B64, dark: 0x5FD3C7)
    static let dotOther = Entry("dot.other", light: 0x8E8E93, dark: 0x98989D)

    static let all: [Entry] = [
        hairline, accentLink, selectedRow, doneGreen, failedRed, cancelledGray, runningBG, runningFG,
        neutralFill, neutralText, warningFG, warningBG, dangerFG, dangerBG, codeFill, editPreviewFill,
        inspectorFill, diffHunkFill, diffAddedFill, diffRemovedFill, claudeBG, claudeFG, codexBG, codexFG,
        opencodeBG, opencodeFG, vibeBG, vibeFG, antigravityBG, antigravityFG, otherBackendBG,
        otherBackendFG,
        windowBG, sidebarBG, cardFill, cardBorder, composerFill, promptBubble, pillFill, selectedSegment, secondaryText,
        liveDot, dotClaude, dotCodex, dotVibe, dotAntigravity, dotOpencode, dotOther
    ]
}
