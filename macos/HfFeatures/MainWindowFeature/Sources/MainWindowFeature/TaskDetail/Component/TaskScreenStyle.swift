//
//  TaskScreenStyle.swift
//  MainWindowFeature
//
//  The task screen's exact metrics and colours, read from HarflowDesign commit 3643d08
//  (`v2/styles/bundle.css` and `v2/styles/tokens.css`) and the task states in `v2/scripts/screens-task.js`
//  (commit 24958cf). Every value cites the CSS rule it comes from.
//  This map is scoped to the task screen: it does not touch `Palette`, HfUI or any other surface.
//  A colour that equals an existing `Palette` value in both appearances reuses that value; every
//  other token is defined here, for this screen only, and listed in `TaskScreenStyle.addedTokens`.
//

import HfUI
import SwiftUI

// MARK: - TaskScreenStyle

enum TaskScreenStyle {
    /// The design commit the stylesheet values were read from; inline task-screen values cite `24958cf` where they appear.
    static let designCommit = "3643d08"

    // MARK: - Tokens

    /// One design token with its light and dark value.
    struct Token: Equatable {
        /// The CSS custom property in `tokens.css`.
        let cssName: String
        let light: UInt32
        let dark: UInt32
        /// The `Palette` entry with identical light and dark values, if any.
        let paletteName: String?
        /// The colour to draw: the existing `Color` for a palette match, else a local appearance-aware colour.
        let color: Color

        init(_ cssName: String, light: UInt32, dark: UInt32, palette: (name: String, color: Color)? = nil) {
            self.cssName = cssName
            self.light = light
            self.dark = dark
            self.paletteName = palette?.name
            self.color = palette?.color ?? Color(light: light, dark: dark)
        }

        static func == (lhs: Token, rhs: Token) -> Bool {
            lhs.cssName == rhs.cssName && lhs.light == rhs.light && lhs.dark == rhs.dark && lhs.paletteName == rhs.paletteName
        }
    }

    /// `tokens.css` `:root` (light) and `[data-theme="dark"]`.
    enum Colors {
        static let surface = Token("--surface", light: 0xFFFFFF, dark: 0x343437)
        static let surfaceHover = Token("--surface-hover", light: 0xEBEBEA, dark: 0x3B3B3E)
        static let surfaceActive = Token("--surface-active", light: 0xE3E3E2, dark: 0x444448)
        static let surfaceSunken = Token("--surface-sunken", light: 0xF4F4F3, dark: 0x262628)
        static let border = Token("--border", light: 0xE2E2E0, dark: 0x404044)
        static let text = Token("--text", light: 0x1D1D1F, dark: 0xECECEE)
        static let textSecondary = Token("--text-secondary", light: 0x56575C, dark: 0xB7B7BC)
        static let textTertiary = Token("--text-tertiary", light: 0x5F6065, dark: 0xADADB3)
        static let accent = Token("--accent", light: 0x2B63D9, dark: 0x7AA5FF)
        static let accentSolid = Token("--accent-solid", light: 0x2B63D9, dark: 0x3D6FDC)
        static let accentSolidHover = Token("--accent-solid-hover", light: 0x2455BD, dark: 0x3462C9)
        static let accentSubtle = Token("--accent-subtle", light: 0xE7EEFC, dark: 0x2F3A52)
        static let onAccent = Token("--on-accent", light: 0xFFFFFF, dark: 0xFFFFFF, palette: ("onAccent", Color.onAccent))

        static let all: [Token] = [
            surface, surfaceHover, surfaceActive, surfaceSunken, border, text, textSecondary, textTertiary,
            accent, accentSolid, accentSolidHover, accentSubtle, onAccent
        ]
    }

    /// Tokens with no equal `Palette` value in both appearances; defined for the task screen only.
    static var addedTokens: [Token] { Colors.all.filter { $0.paletteName == nil } }

    // MARK: - Shared steps

    /// `tokens.css` `:root` spacing and radius scales.
    enum Scale {
        static let space1: CGFloat = 4
        static let space2: CGFloat = 8
        static let space3: CGFloat = 12
        static let space4: CGFloat = 16
        static let space5: CGFloat = 24
        static let space6: CGFloat = 32
        static let radiusSmall: CGFloat = 6
        static let radiusMedium: CGFloat = 8
        static let radiusLarge: CGFloat = 12
        static let radiusExtraLarge: CGFloat = 18
        /// `--content-width`.
        static let contentWidth: CGFloat = 760
    }

    /// A font size and line height in points.
    struct TextSpec: Equatable {
        let size: CGFloat
        let lineHeight: CGFloat
    }

    // MARK: - Transcript

    /// `.hd-transcript`: `max-width: var(--content-width)`, `padding: space-5 space-6 space-4`, `gap: space-4`.
    enum Transcript {
        static let maxWidth = Scale.contentWidth
        static let paddingTop = Scale.space5
        static let paddingHorizontal = Scale.space6
        static let paddingBottom = Scale.space4
        static let gap = Scale.space4
    }

    /// `.hd-msg-user`: right-aligned, `max-width: 80%`, `surface-active` fill, `radius-lg`,
    /// `padding: 10px 14px`, 14/22.
    enum UserBubble {
        static let maxWidthFraction: CGFloat = 0.8
        static let fill = Colors.surfaceActive
        static let cornerRadius = Scale.radiusLarge
        static let paddingVertical: CGFloat = 10
        static let paddingHorizontal: CGFloat = 14
        static let text = TextSpec(size: 14, lineHeight: 22)
    }

    /// `.hd-msg-agent` and its `p`, `ul` and inline `code` rules.
    enum AgentProse {
        static let text = TextSpec(size: 14, lineHeight: 22)
        static let color = Colors.text
        /// `.hd-msg-agent p`: `margin: 0 0 10px` (none after the last paragraph).
        static let paragraphSpacing: CGFloat = 10
        /// `.hd-msg-agent ul`: `margin: 0 0 10px; padding-left: 20px`.
        static let listSpacing: CGFloat = 10
        static let listIndent: CGFloat = 20
    }

    /// `.hd-msg-agent code`: mono 12.5, `surface-sunken` fill, `padding: 1px 5px`, radius 4.
    enum InlineCode {
        static let fontSize: CGFloat = 12.5
        static let fill = Colors.surfaceSunken
        static let paddingVertical: CGFloat = 1
        static let paddingHorizontal: CGFloat = 5
        static let cornerRadius: CGFloat = 4
    }

    /// `.hd-turn-sep`: `gap: space-2`, 12/16, `text-tertiary`; its `::before`/`::after` are 1 pt `border` rules.
    enum TurnSeparator {
        static let gap = Scale.space2
        static let text = TextSpec(size: 12, lineHeight: 16)
        static let color = Colors.textTertiary
        static let ruleThickness: CGFloat = 1
        static let ruleColor = Colors.border
    }

    /// `.hd-working`: `gap: 8px`, 13 pt, `text-secondary`; the glyph is `.hd-glyph--running`
    /// (14 pt, 2 pt `accent-subtle` ring with an `accent` leading arc, 1 pt margin, 1 s spin).
    enum Working {
        static let gap: CGFloat = 8
        static let fontSize: CGFloat = 13
        static let color = Colors.textSecondary
        static let glyphSize: CGFloat = 14
        static let glyphRingWidth: CGFloat = 2
        static let glyphMargin: CGFloat = 1
        static let glyphRing = Colors.accentSubtle
        static let glyphArc = Colors.accent
        static let spinDuration: TimeInterval = 1
    }

    // MARK: - Tool rows

    /// `.hd-tool` and `.hd-tool__head`.
    enum ToolHead {
        /// `.hd-tool`: `border-radius: radius-md`.
        static let cornerRadius = Scale.radiusMedium
        static let gap: CGFloat = 8
        static let minHeight: CGFloat = 28
        static let paddingVertical: CGFloat = 3
        static let paddingHorizontal: CGFloat = 6
        /// `margin: 0 -6px` pulls the hover plate outside the text column.
        static let horizontalBleed: CGFloat = 6
        static let hoverCornerRadius = Scale.radiusSmall
        static let text = TextSpec(size: 13, lineHeight: 18)
        static let color = Colors.textSecondary
        static let hoverFill = Colors.surfaceHover
        static let hoverColor = Colors.text
        /// `.hd-tool__head .hd-i`.
        static let iconColor = Colors.textTertiary
        /// `.hd-tool__summary code`: mono 12, `text`.
        static let summaryCodeSize: CGFloat = 12
        static let summaryCodeColor = Colors.text
        /// `.hd-tool__meta`: 12 pt, `text-tertiary`, tabular numerals.
        static let metaSize: CGFloat = 12
        static let metaColor = Colors.textTertiary
    }

    /// `.hd-tool__body`: `margin: 4px 0 2px 22px`, `surface-sunken` fill, `radius-md`,
    /// `padding: 10px 12px`, mono 12/18, `text-secondary`, `max-height: 220px`.
    enum ToolBody {
        static let marginTop: CGFloat = 4
        static let marginBottom: CGFloat = 2
        static let marginLeading: CGFloat = 22
        static let fill = Colors.surfaceSunken
        static let cornerRadius = Scale.radiusMedium
        static let paddingVertical: CGFloat = 10
        static let paddingHorizontal: CGFloat = 12
        static let text = TextSpec(size: 12, lineHeight: 18)
        static let color = Colors.textSecondary
        static let maxHeight: CGFloat = 220
        /// `.hd-tool__body b`: `text`, weight 500.
        static let emphasisColor = Colors.text
        static let emphasisWeight = Font.Weight.medium
    }

    // MARK: - Composer

    /// One layer of `--shadow-composer`; the ink is black, its opacity differs by appearance.
    struct ShadowLayer: Equatable {
        let offsetY: CGFloat
        let blur: CGFloat
        let lightOpacity: Double
        let darkOpacity: Double
    }

    /// `.hd-composer` and its parts.
    enum Composer {
        static let fill = Colors.surface
        static let cornerRadius = Scale.radiusExtraLarge
        static let borderWidth: CGFloat = 1
        static let borderColor = Colors.border
        static let paddingTop = Scale.space3
        static let paddingTrailing = Scale.space3
        static let paddingBottom = Scale.space2
        static let paddingLeading = Scale.space4
        static let gap = Scale.space2
        /// `--shadow-composer`: `0 1px 2px` then `0 4px 16px`, black ink (`Color.shadow`).
        static let shadow: [ShadowLayer] = [
            ShadowLayer(offsetY: 1, blur: 2, lightOpacity: 0.04, darkOpacity: 0.3),
            ShadowLayer(offsetY: 4, blur: 16, lightOpacity: 0.06, darkOpacity: 0.25)
        ]

        /// `.hd-composer__input`: 14/22, `text`, `padding: 2px 0`; placeholder `text-tertiary`. The base rule
        /// sets `min-height: 44px`, but every task state in `v2/scripts/screens-task.js` (24958cf)
        /// overrides it inline with `rows="2"` and `style="min-height: 28px;"`, so those are used here.
        static let inputText = TextSpec(size: 14, lineHeight: 22)
        static let inputColor = Colors.text
        static let inputRows = 2
        static let inputMinHeight: CGFloat = 28
        static let inputPaddingVertical: CGFloat = 2
        static let placeholderColor = Colors.textTertiary

        /// `.hd-composer__bar`: `gap: 6px`.
        static let barGap: CGFloat = 6

        /// `.hd-composer__send`: 32 pt circle, `accent-solid` (hover `accent-solid-hover`), `on-accent`;
        /// disabled uses `surface-active` with `text-tertiary`.
        static let sendSize: CGFloat = 32
        static let sendFill = Colors.accentSolid
        static let sendHoverFill = Colors.accentSolidHover
        static let sendForeground = Colors.onAccent
        static let sendDisabledFill = Colors.surfaceActive
        static let sendDisabledForeground = Colors.textTertiary
    }

    /// The composer's wrapper on the task screen (`v2/scripts/screens-task.js`): `max-width: var(--content-width)`,
    /// `padding: space-2 space-6 space-5`.
    enum ComposerWrapper {
        static let maxWidth = Scale.contentWidth
        static let paddingTop = Scale.space2
        static let paddingHorizontal = Scale.space6
        static let paddingBottom = Scale.space5
    }

    /// `--font-mono` / `.code`: `ui-monospace` resolves to the system monospaced face.
    static let monoDesign = Font.Design.monospaced
}
