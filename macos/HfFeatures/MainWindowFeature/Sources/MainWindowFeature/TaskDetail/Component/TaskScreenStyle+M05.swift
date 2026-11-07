//
//  TaskScreenStyle+M05.swift
//  MainWindowFeature
//
//  The M05 task screen's additional tokens and metrics, read from HarflowDesign commit 17739e4
//  (`v2/styles/tokens.css`, `v2/styles/bundle.css` and `v2/styles/m05-proposal.css`). Every group below
//  cites that commit and the CSS rule each value comes from. The M05 design is a proposal, not an
//  approved design. Nothing renders from these values yet.
//  No colour here equals an existing `Palette` value in both appearances, so none reuses one.
//
//  Rules not mapped (not needed by the groups below): `.hd-m05-panenote`, `.hd-m05-artifact`,
//  `.hd-m05-request`, `.hd-m05-repo`, `.hd-m05-scope`, `.hd-m05-record`, `.hd-m05-skel`,
//  `.hd-m05-conn`, and the `.hd-m05-board`/`-catalog` specimen rules.
//

import HfUI
import SwiftUI

extension TaskScreenStyle {
    /// The design commit the M05 values below were read from; `designCommit` stays the earlier pin.
    static let m05DesignCommit = "17739e4"

    // MARK: - Colours

    /// A background and foreground pair for one variant.
    struct ColorPair: Equatable {
        let background: Token
        let foreground: Token
    }
}

// MARK: - Tokens (17739e4)

extension TaskScreenStyle.Colors {
    /// `tokens.css` at 17739e4, `:root` (light) and `[data-theme="dark"]`.
    static let attention = TaskScreenStyle.Token("--attention", light: 0xAD4210, dark: 0xF08A4B)
    static let attentionSubtle = TaskScreenStyle.Token("--attention-subtle", light: 0xFBEEE6, dark: 0x47352B)
    static let success = TaskScreenStyle.Token("--success", light: 0x25793A, dark: 0x6CC785)
    static let successSubtle = TaskScreenStyle.Token("--success-subtle", light: 0xE5F3E8, dark: 0x2C3F31)
    static let danger = TaskScreenStyle.Token("--danger", light: 0xC0352C, dark: 0xF2827A)
    static let dangerSubtle = TaskScreenStyle.Token("--danger-subtle", light: 0xFBE9E7, dark: 0x4A3230)
    static let warning = TaskScreenStyle.Token("--warning", light: 0x8A5A00, dark: 0xE5B454)
    static let warningSubtle = TaskScreenStyle.Token("--warning-subtle", light: 0xFBF1DC, dark: 0x45391F)
    /// Used by `.hd-diff__line--add` and `--del`.
    static let diffAdd = TaskScreenStyle.Token("--diff-add", light: 0xE3F4E6, dark: 0x2A3D2E)
    static let diffRemove = TaskScreenStyle.Token("--diff-remove", light: 0xFBE7E5, dark: 0x43302E)

    /// The tokens added at 17739e4, none of which equals a `Palette` value in both appearances.
    static let m05: [TaskScreenStyle.Token] = [
        attention, attentionSubtle, success, successSubtle, danger, dangerSubtle, warning, warningSubtle, diffAdd, diffRemove
    ]
}

extension TaskScreenStyle {

    // MARK: - Layout and shadows (17739e4)

    /// `tokens.css` at 17739e4, `:root`.
    enum Layout {
        /// `--radius-full`.
        static let radiusFull: CGFloat = 999
        /// `--titlebar-height`.
        static let titlebarHeight: CGFloat = 44
        /// `--pane-width`.
        static let paneWidth: CGFloat = 420
    }

    /// A one point ring such as the `0 0 0 1px` layer of `--shadow-popover`. Unlike `ShadowLayer`, its ink
    /// differs by appearance.
    struct RingLayer: Equatable {
        let width: CGFloat
        /// The ink as `0xRRGGBB`, with its opacity, in each appearance.
        let lightInk: UInt32
        let lightOpacity: Double
        let darkInk: UInt32
        let darkOpacity: Double
    }

    /// `--shadow-popover` and `--shadow-dialog` at 17739e4; offsets are vertical only, spread is zero.
    enum Shadows {
        /// `--shadow-popover`: `0 8px 28px` (black `.12` light, `.45` dark), then the ring.
        static let popover: [ShadowLayer] = [ShadowLayer(offsetY: 8, blur: 28, lightOpacity: 0.12, darkOpacity: 0.45)]
        /// `--shadow-popover` ring: `0 0 0 1px rgba(0,0,0,.05)` light, `rgba(255,255,255,.06)` dark.
        static let popoverRing = RingLayer(width: 1, lightInk: 0x000000, lightOpacity: 0.05, darkInk: 0xFFFFFF, darkOpacity: 0.06)
        /// `--shadow-dialog`: `0 20px 60px` (black `.2` light, `.55` dark); no ring.
        static let dialog: [ShadowLayer] = [ShadowLayer(offsetY: 20, blur: 60, lightOpacity: 0.2, darkOpacity: 0.55)]
    }

    // MARK: - Top bar (17739e4)

    /// `.hd-m05-bar` (`m05-proposal.css`) with `.hd-topbar__title` and `.hd-topbar__meta` (`bundle.css`).
    enum TopBar {
        /// `height: var(--titlebar-height)`.
        static let height = Layout.titlebarHeight
        /// `gap: var(--space-2)`.
        static let gap = Scale.space2
        /// `padding: 0 var(--space-3) 0 var(--space-4)`.
        static let paddingLeading = Scale.space4
        static let paddingTrailing = Scale.space3
        /// `border-bottom: 1px solid var(--border)`.
        static let borderWidth: CGFloat = 1
        static let borderColor = Colors.border
        /// `.hd-m05-bar__center` and `__left`: `gap: var(--space-2)`.
        static let groupGap = Scale.space2
        /// `.hd-m05-bar__right`: `gap: var(--space-1)`.
        static let actionsGap = Scale.space1
        /// `.hd-m05-bar__center .hd-topbar__title`: `min-width: 80px`.
        static let titleMinWidth: CGFloat = 80
        /// `.hd-topbar__title`: 14/20, weight 600, single line with ellipsis.
        static let title = TextSpec(size: 14, lineHeight: 20)
        static let titleWeight = Font.Weight.semibold
        /// `.hd-topbar__meta`: 12/16, `text-tertiary`, no wrap.
        static let meta = TextSpec(size: 12, lineHeight: 16)
        static let metaColor = Colors.textTertiary
    }

    // MARK: - Badge (17739e4)

    /// `.hd-badge` and its variants (`bundle.css`), plus `.hd-m05-badge--neutral` (`m05-proposal.css`).
    enum Badge {
        /// `height: 22px`.
        static let height: CGFloat = 22
        /// `padding: 0 8px`.
        static let paddingHorizontal: CGFloat = 8
        /// `gap: 5px`.
        static let gap: CGFloat = 5
        /// `border-radius: var(--radius-full)`.
        static let cornerRadius = Layout.radiusFull
        /// `font-size: 12px; line-height: 16px; font-weight: 500`.
        static let text = TextSpec(size: 12, lineHeight: 16)
        static let weight = Font.Weight.medium
        /// `.hd-badge .hd-i`: 12 by 12.
        static let iconSize: CGFloat = 12
        /// `.hd-badge__spin`: 10 pt circle, 1.5 pt `currentColor` border with a clear trailing edge.
        static let spinSize: CGFloat = 10
        static let spinBorderWidth: CGFloat = 1.5

        /// `.hd-badge`: `surface-hover` on `text-secondary`.
        static let base = ColorPair(background: Colors.surfaceHover, foreground: Colors.textSecondary)
        /// `.hd-badge--running`.
        static let running = ColorPair(background: Colors.accentSubtle, foreground: Colors.accent)
        /// `.hd-badge--done`.
        static let done = ColorPair(background: Colors.successSubtle, foreground: Colors.success)
        /// `.hd-badge--failed`.
        static let failed = ColorPair(background: Colors.dangerSubtle, foreground: Colors.danger)
        /// `.hd-badge--attention`.
        static let attention = ColorPair(background: Colors.attentionSubtle, foreground: Colors.attention)
        /// `.hd-badge--warning`.
        static let warning = ColorPair(background: Colors.warningSubtle, foreground: Colors.warning)
        /// `.hd-m05-badge--neutral`: `surface-active` on `text-secondary`.
        static let neutral = ColorPair(background: Colors.surfaceActive, foreground: Colors.textSecondary)
        /// `.hd-badge--plain`: transparent, `padding: 0`, `height: auto`; keeps the base foreground.
        static let plainPadding: CGFloat = 0
    }

    // MARK: - Chip (17739e4)

    /// `.hd-m05-chip` (`m05-proposal.css`).
    enum Chip {
        static let height: CGFloat = 24
        /// `padding: 0 8px`.
        static let paddingHorizontal: CGFloat = 8
        static let gap: CGFloat = 4
        static let borderWidth: CGFloat = 1
        static let borderColor = Colors.border
        static let cornerRadius = Layout.radiusFull
        /// `background: transparent; color: var(--text-secondary); font-size: 12px`.
        static let fontSize: CGFloat = 12
        static let color = Colors.textSecondary
        /// `.hd-m05-chip:hover`.
        static let hoverFill = Colors.surfaceHover
        static let hoverColor = Colors.text
    }

    // MARK: - Pane head, tabs and body (17739e4)

    /// `.hd-pane` and `.hd-pane__head` (`bundle.css`).
    enum PaneHead {
        /// `.hd-pane`: `width: var(--pane-width)`, `border-left: 1px solid var(--border)`, `background: var(--bg)`.
        static let width = Layout.paneWidth
        static let leadingBorderWidth: CGFloat = 1
        static let borderColor = Colors.border
        static let fill = Colors.pageBackground
        /// `.hd-pane__head`: `height: var(--titlebar-height)`, `gap: var(--space-2)`, `padding: 0 var(--space-3)`,
        /// `border-bottom: 1px solid var(--border)`.
        static let height = Layout.titlebarHeight
        static let gap = Scale.space2
        static let paddingHorizontal = Scale.space3
        static let bottomBorderWidth: CGFloat = 1
        /// `.hd-m05-body--overlay .hd-m05-pane`: the overlay pane carries `--shadow-popover`.
        static let overlayShadow = Shadows.popover
        static let overlayRing = Shadows.popoverRing
    }

    /// `.hd-tabs`, `.hd-tab` and `.hd-tab__count` (`bundle.css`).
    enum PaneTab {
        /// `.hd-tabs`: `gap: 2px`.
        static let gap: CGFloat = 2
        static let height: CGFloat = 30
        /// `padding: 0 10px`.
        static let paddingHorizontal: CGFloat = 10
        static let cornerRadius = Scale.radiusSmall
        /// `font-size: 13px; font-weight: 500`; `gap: 6px` between label and count.
        static let fontSize: CGFloat = 13
        static let weight = Font.Weight.medium
        static let gapToCount: CGFloat = 6
        static let color = Colors.textSecondary
        /// `.hd-tab:hover`.
        static let hoverFill = Colors.surfaceHover
        static let hoverColor = Colors.text
        /// `.hd-tab.is-active`.
        static let activeFill = Colors.surfaceActive
        static let activeColor = Colors.text
        /// `.hd-tab__count`: 12 pt, `text-tertiary`, tabular numerals.
        static let countSize: CGFloat = 12
        static let countColor = Colors.textTertiary
    }

    /// `.hd-m05-panebody` (`m05-proposal.css`): `padding: var(--space-3)`, column, `gap: var(--space-2)`.
    enum PaneBody {
        static let padding = Scale.space3
        static let gap = Scale.space2
    }

    // MARK: - Facts group (17739e4)

    /// `.hd-m05-facts` (`m05-proposal.css`): the Events tab's collapsible groups.
    enum FactsSummary {
        /// `.hd-m05-facts`: `border-bottom: 1px solid var(--border)`.
        static let borderWidth: CGFloat = 1
        static let borderColor = Colors.border
        /// `.hd-m05-facts>summary`: `gap: 6px`, `min-height: 28px`, weight 500, 13 pt.
        static let gap: CGFloat = 6
        static let minHeight: CGFloat = 28
        static let weight = Font.Weight.medium
        static let fontSize: CGFloat = 13
        /// `.hd-m05-facts[open]>summary>.hd-i-chevron-right`: `rotate(90deg)`.
        static let expandedChevronDegrees: Double = 90
    }

    /// `.hd-m05-facts__body`, its definition list and `.hd-m05-h` (`m05-proposal.css`).
    enum FactsBody {
        /// `padding: 0 0 8px 20px`.
        static let paddingBottom: CGFloat = 8
        static let paddingLeading: CGFloat = 20
        /// `font-size: 13px; line-height: 19px`.
        static let text = TextSpec(size: 13, lineHeight: 19)
        /// `.hd-m05-facts dl`: two columns (`auto 1fr`), `gap: 2px 10px`, `margin: 4px 0`, 12/17.
        static let rowGap: CGFloat = 2
        static let columnGap: CGFloat = 10
        static let listMarginVertical: CGFloat = 4
        static let listText = TextSpec(size: 12, lineHeight: 17)
        /// `.hd-m05-facts dt`: `text-tertiary`.
        static let termColor = Colors.textTertiary
        /// `.hd-m05-h`: `margin: 10px 0 2px`, 12 pt, weight 600, `text-secondary`.
        static let headingMarginTop: CGFloat = 10
        static let headingMarginBottom: CGFloat = 2
        static let headingSize: CGFloat = 12
        static let headingWeight = Font.Weight.semibold
        static let headingColor = Colors.textSecondary
    }

    // MARK: - Banner (17739e4)

    /// `.hd-banner` and its variants (`bundle.css`).
    enum Banner {
        /// `gap: 10px`, `padding: 10px 14px`, `border-radius: var(--radius-md)`.
        static let gap: CGFloat = 10
        static let paddingVertical: CGFloat = 10
        static let paddingHorizontal: CGFloat = 14
        static let cornerRadius = Scale.radiusMedium
        /// `font-size: 13px; line-height: 20px`; `color: var(--text)`.
        static let text = TextSpec(size: 13, lineHeight: 20)
        static let color = Colors.text
        /// Default (danger): `danger-subtle` fill, `.hd-banner > .hd-i` in `danger`.
        static let danger = ColorPair(background: Colors.dangerSubtle, foreground: Colors.danger)
        /// `.hd-banner--warning`: `warning-subtle` fill, icon in `warning`.
        static let warning = ColorPair(background: Colors.warningSubtle, foreground: Colors.warning)
        /// `.hd-banner > .hd-i`: `margin-top: 2px`.
        static let iconTopInset: CGFloat = 2
        /// `.hd-banner__title`: weight 600.
        static let titleWeight = Font.Weight.semibold
    }

    // MARK: - Notice (17739e4)

    /// `.hd-m05-notice` and `.hd-m05-notice--warning` (`m05-proposal.css`).
    enum Notice {
        static let gap: CGFloat = 10
        static let paddingVertical: CGFloat = 8
        static let paddingHorizontal: CGFloat = 12
        static let cornerRadius = Scale.radiusMedium
        /// Default fill `surface-sunken`; `font-size: 13px; line-height: 19px`.
        static let fill = Colors.surfaceSunken
        static let text = TextSpec(size: 13, lineHeight: 19)
        /// `--warning`: `warning-subtle` fill and `warning` icon.
        static let warning = ColorPair(background: Colors.warningSubtle, foreground: Colors.warning)
    }

    // MARK: - Menu (17739e4)

    /// `.hd-menu`, `__label`, `__item`, `__sep` and related rules (`bundle.css`); `.hd-m05-menu` offset (`m05-proposal.css`).
    enum Menu {
        static let minWidth: CGFloat = 240
        static let maxWidth: CGFloat = 320
        static let fill = Colors.surface
        static let cornerRadius = Scale.radiusLarge
        /// `box-shadow: var(--shadow-popover)`.
        static let shadow = Shadows.popover
        static let ring = Shadows.popoverRing
        /// `padding: var(--space-1)`, `gap: 1px`.
        static let padding = Scale.space1
        static let gap: CGFloat = 1
        /// `.hd-m05-menu`: `top: calc(100% + 6px)`.
        static let anchorOffset: CGFloat = 6

        /// `.hd-menu__label`: `padding: 6px 10px 4px`, 12/16, `text-tertiary`, weight 500.
        static let labelPaddingTop: CGFloat = 6
        static let labelPaddingHorizontal: CGFloat = 10
        static let labelPaddingBottom: CGFloat = 4
        static let labelText = TextSpec(size: 12, lineHeight: 16)
        static let labelColor = Colors.textTertiary
        static let labelWeight = Font.Weight.medium

        /// `.hd-menu__item`: `gap: 10px`, `min-height: 32px`, `padding: 5px 10px`, `radius-md`, 13/18, `text`.
        static let itemGap: CGFloat = 10
        static let itemMinHeight: CGFloat = 32
        static let itemPaddingVertical: CGFloat = 5
        static let itemPaddingHorizontal: CGFloat = 10
        static let itemCornerRadius = Scale.radiusMedium
        static let itemText = TextSpec(size: 13, lineHeight: 18)
        static let itemColor = Colors.text
        /// `.hd-menu__item:hover`.
        static let itemHoverFill = Colors.surfaceHover
        /// `.hd-menu__item .hd-i`.
        static let itemIconColor = Colors.textSecondary
        /// `.hd-menu__item-hint`: 12/16, `text-tertiary`.
        static let hintText = TextSpec(size: 12, lineHeight: 16)
        static let hintColor = Colors.textTertiary
        /// `.hd-menu__check`.
        static let checkColor = Colors.accent
        /// `.hd-menu__item--danger`, including its icon.
        static let dangerColor = Colors.danger
        /// `.hd-menu__item[disabled]`: `opacity: .45`.
        static let disabledOpacity = 0.45

        /// `.hd-menu__sep`: `height: 1px`, `border` fill, `margin: var(--space-1) 6px`.
        static let separatorThickness: CGFloat = 1
        static let separatorColor = Colors.border
        static let separatorMarginVertical = Scale.space1
        static let separatorMarginHorizontal: CGFloat = 6
    }

    // MARK: - Dialog (17739e4)

    /// `.hd-dialog` and its parts (`bundle.css`); `.hd-m05-scrim` (`m05-proposal.css`).
    enum Dialog {
        static let width: CGFloat = 440
        static let fill = Colors.surface
        static let cornerRadius = Scale.radiusLarge
        /// `box-shadow: var(--shadow-dialog)`.
        static let shadow = Shadows.dialog
        /// `padding: var(--space-5)`, `gap: var(--space-3)`.
        static let padding = Scale.space5
        static let gap = Scale.space3
        /// `.hd-dialog__title`: 15/22, weight 600.
        static let title = TextSpec(size: 15, lineHeight: 22)
        static let titleWeight = Font.Weight.semibold
        /// `.hd-dialog__text`: 13/20, `text-secondary`.
        static let text = TextSpec(size: 13, lineHeight: 20)
        static let textColor = Colors.textSecondary
        /// `.hd-dialog__actions`: end-aligned, `gap: 8px`, `margin-top: var(--space-2)`.
        static let actionsGap: CGFloat = 8
        static let actionsMarginTop = Scale.space2
        /// `.hd-m05-scrim`: `color-mix(in srgb, var(--bg) 55%, transparent)`.
        static let scrimFill = Colors.pageBackground
        static let scrimOpacity = 0.55
    }

    // MARK: - Resource card (17739e4)

    /// `.hd-m05-resource` (`m05-proposal.css`).
    enum ResourceCard {
        /// Column, `gap: 4px`, `padding: 12px`, 13 pt.
        static let gap: CGFloat = 4
        static let padding: CGFloat = 12
        static let fontSize: CGFloat = 13
        static let borderWidth: CGFloat = 1
        static let borderColor = Colors.border
        static let cornerRadius = Scale.radiusMedium
        static let fill = Colors.surface
        /// `.hd-m05-resource a`.
        static let linkColor = Colors.accent
    }

    // MARK: - Changes rows (17739e4)

    /// `.hd-file`, `.hd-m05-file` and the status, tag and row-state rules.
    enum ChangeRow {
        /// `.hd-file` (`bundle.css`): `gap: 8px`, `height: 32px`, `padding: 0 var(--space-3)`, 13 pt, `radius-sm`.
        static let gap: CGFloat = 8
        static let height: CGFloat = 32
        static let paddingHorizontal = Scale.space3
        static let fontSize: CGFloat = 13
        static let cornerRadius = Scale.radiusSmall
        static let hoverFill = Colors.surfaceHover
        /// `.hd-m05-file` (`m05-proposal.css`): `height: 28px`, `padding: 0 6px`; `.is-selected` is `surface-active`;
        /// `--dim` is `opacity: .7`.
        static let compactHeight: CGFloat = 28
        static let compactPaddingHorizontal: CGFloat = 6
        static let selectedFill = Colors.surfaceActive
        static let dimOpacity = 0.7
        /// `.hd-file__path`: mono 12.
        static let pathSize: CGFloat = 12
        /// `.hd-file__add` and `.hd-file__del`: 12 pt, tabular numerals.
        static let countSize: CGFloat = 12
        static let addColor = Colors.success
        static let deleteColor = Colors.danger
        /// `.hd-m05-status`: 14 pt wide, mono 11, weight 600, centred, `text-tertiary`.
        static let statusWidth: CGFloat = 14
        static let statusSize: CGFloat = 11
        static let statusWeight = Font.Weight.semibold
        static let statusColor = Colors.textTertiary
        /// `.hd-m05-status--added`, `--deleted`, `--modified`, `--unmerged`.
        static let statusAdded = Colors.success
        static let statusDeleted = Colors.danger
        static let statusModified = Colors.attention
        static let statusUnmerged = Colors.danger
        /// `.hd-m05-rowstate`: `max-width: 150px`, 11 pt, `text-tertiary`.
        static let rowStateMaxWidth: CGFloat = 150
        static let rowStateSize: CGFloat = 11
        static let rowStateColor = Colors.textTertiary
    }

    /// `.hd-m05-tag` and its variants (`m05-proposal.css`).
    enum ChangeTag {
        static let height: CGFloat = 18
        /// `padding: 0 6px`.
        static let paddingHorizontal: CGFloat = 6
        static let cornerRadius = Scale.radiusSmall
        /// `font-size: 11px; font-weight: 500`.
        static let fontSize: CGFloat = 11
        static let weight = Font.Weight.medium
        /// Base: `surface-active` on `text-secondary`.
        static let base = ColorPair(background: Colors.surfaceActive, foreground: Colors.textSecondary)
        /// `--warn`, `--ok`, `--info`.
        static let warn = ColorPair(background: Colors.warningSubtle, foreground: Colors.warning)
        static let ok = ColorPair(background: Colors.successSubtle, foreground: Colors.success)
        static let info = ColorPair(background: Colors.accentSubtle, foreground: Colors.accent)
    }

    /// `.hd-diff` and its lines (`bundle.css`).
    enum Diff {
        /// Mono 12/19, `border: 1px solid var(--border)`, `radius-md`, `surface` fill.
        static let text = TextSpec(size: 12, lineHeight: 19)
        static let borderWidth: CGFloat = 1
        static let borderColor = Colors.border
        static let cornerRadius = Scale.radiusMedium
        static let fill = Colors.surface
        /// `.hd-diff__line`: `padding: 0 10px`, no wrapping.
        static let linePaddingHorizontal: CGFloat = 10
        static let addFill = Colors.diffAdd
        static let deleteFill = Colors.diffRemove
        /// `.hd-diff__line--hunk`: `text-tertiary` on `surface-sunken`.
        static let hunkColor = Colors.textTertiary
        static let hunkFill = Colors.surfaceSunken
        /// `.hd-diff__sign`: 14 pt wide, `text-tertiary`.
        static let signWidth: CGFloat = 14
        static let signColor = Colors.textTertiary
    }

    // MARK: - Derived box (17739e4)

    /// `.hd-m05-derived` (`m05-proposal.css`): `padding: 8px 10px`, `surface-sunken`, `radius-sm`, 13/19;
    /// `.hd-m05-derived p` has `margin: 2px 0`.
    enum DerivedBox {
        static let paddingVertical: CGFloat = 8
        static let paddingHorizontal: CGFloat = 10
        static let fill = Colors.surfaceSunken
        static let cornerRadius = Scale.radiusSmall
        static let text = TextSpec(size: 13, lineHeight: 19)
        static let paragraphMarginVertical: CGFloat = 2
    }
}
