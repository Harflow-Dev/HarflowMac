//
//  TaskScreenStyleM05Tests.swift
//  MainWindowFeatureTests
//

@testable import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskScreenStyleM05Tests

@MainActor
struct TaskScreenStyleM05Tests {
    private typealias Style = TaskScreenStyle

    /// `tokens.css` at 17739e4, light then dark.
    private static let pinnedTokens: [(cssName: String, light: UInt32, dark: UInt32)] = [
        ("--attention", 0xAD4210, 0xF08A4B), ("--attention-subtle", 0xFBEEE6, 0x47352B),
        ("--success", 0x25793A, 0x6CC785), ("--success-subtle", 0xE5F3E8, 0x2C3F31),
        ("--danger", 0xC0352C, 0xF2827A), ("--danger-subtle", 0xFBE9E7, 0x4A3230),
        ("--warning", 0x8A5A00, 0xE5B454), ("--warning-subtle", 0xFBF1DC, 0x45391F),
        ("--diff-add", 0xE3F4E6, 0x2A3D2E), ("--diff-remove", 0xFBE7E5, 0x43302E)
    ]

    @Test func givenTheM05DesignCommit_whenRead_thenItIsPinnedAndTheEarlierPinIsKept() {
        // given / when / then
        #expect(Style.m05DesignCommit == "17739e4")
        #expect(Style.designCommit == "3643d08")
    }

    @Test func givenTheM05Tokens_whenComparedToTheDesign_thenEveryTokenHasExactLightAndDarkValues() {
        // given
        let mapped = Dictionary(uniqueKeysWithValues: Style.Colors.m05.map { ($0.cssName, $0) })

        // when / then
        #expect(Style.Colors.m05.count == Self.pinnedTokens.count)
        #expect(Set(mapped.keys) == Set(Self.pinnedTokens.map(\.cssName)))
        for pinned in Self.pinnedTokens {
            #expect(mapped[pinned.cssName]?.light == pinned.light, "\(pinned.cssName) light")
            #expect(mapped[pinned.cssName]?.dark == pinned.dark, "\(pinned.cssName) dark")
        }
    }

    @Test func givenTheNamedTokenConstants_whenComparedToTheList_thenEachIsListedOnce() {
        // given
        let named: [Style.Token] = [
            Style.Colors.attention, Style.Colors.attentionSubtle, Style.Colors.success, Style.Colors.successSubtle,
            Style.Colors.danger, Style.Colors.dangerSubtle, Style.Colors.warning, Style.Colors.warningSubtle,
            Style.Colors.diffAdd, Style.Colors.diffRemove
        ]

        // when / then
        #expect(Style.Colors.m05 == named)
        #expect(Set(Style.Colors.m05.map(\.cssName)).count == Style.Colors.m05.count)
    }

    @Test func givenTheM05Tokens_whenComparedToPalette_thenNoneEqualsAPaletteValueInBothAppearances() {
        // given
        let palette = Palette.all

        // when / then
        for token in Style.Colors.m05 {
            #expect(token.paletteName == nil, "\(token.cssName) is mapped to a palette entry")
            let match = palette.first { $0.light == token.light && $0.dark == token.dark }
            #expect(match == nil, "\(token.cssName) equals Palette \(match?.name ?? "")")
        }
    }

    @Test func givenTheM05Tokens_whenComparedToTheEarlierTokens_thenNoNameIsReused() {
        // given
        let earlier = Set(Style.Colors.all.map(\.cssName))

        // when / then
        #expect(Set(Style.Colors.m05.map(\.cssName)).isDisjoint(with: earlier))
    }

    @Test func givenTheLayoutAndShadowTokens_whenRead_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.Layout.radiusFull == 999)
        #expect(Style.Layout.titlebarHeight == 44)
        #expect(Style.Layout.paneWidth == 420)
        #expect(Style.Shadows.popover == [Style.ShadowLayer(offsetY: 8, blur: 28, lightOpacity: 0.12, darkOpacity: 0.45)])
        #expect(Style.Shadows.popoverRing == Style.RingLayer(width: 1, lightInk: 0x000000, lightOpacity: 0.05,
                                                             darkInk: 0xFFFFFF, darkOpacity: 0.06))
        #expect(Style.Shadows.dialog == [Style.ShadowLayer(offsetY: 20, blur: 60, lightOpacity: 0.2, darkOpacity: 0.55)])
    }

    @Test func givenTheTopBarAndBadgeRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.TopBar.height == 44)
        #expect(Style.TopBar.gap == 8)
        #expect(Style.TopBar.paddingLeading == 16)
        #expect(Style.TopBar.paddingTrailing == 12)
        #expect(Style.TopBar.borderWidth == 1)
        #expect(Style.TopBar.borderColor == Style.Colors.border)
        #expect(Style.TopBar.groupGap == 8)
        #expect(Style.TopBar.actionsGap == 4)
        #expect(Style.TopBar.titleMinWidth == 80)
        #expect(Style.TopBar.title == .init(size: 14, lineHeight: 20))
        #expect(Style.TopBar.titleWeight == .semibold)
        #expect(Style.TopBar.meta == .init(size: 12, lineHeight: 16))
        #expect(Style.TopBar.metaColor == Style.Colors.textTertiary)

        #expect(Style.Badge.height == 22)
        #expect(Style.Badge.paddingHorizontal == 8)
        #expect(Style.Badge.gap == 5)
        #expect(Style.Badge.cornerRadius == 999)
        #expect(Style.Badge.text == .init(size: 12, lineHeight: 16))
        #expect(Style.Badge.weight == .medium)
        #expect(Style.Badge.iconSize == 12)
        #expect(Style.Badge.spinSize == 10)
        #expect(Style.Badge.spinBorderWidth == 1.5)
        #expect(Style.Badge.plainPadding == 0)
    }

    @Test func givenTheBadgeVariants_whenRead_thenEachPairsTheDesignedColours() {
        // given / when / then
        #expect(Style.Badge.base == .init(background: Style.Colors.surfaceHover, foreground: Style.Colors.textSecondary))
        #expect(Style.Badge.running == .init(background: Style.Colors.accentSubtle, foreground: Style.Colors.accent))
        #expect(Style.Badge.done == .init(background: Style.Colors.successSubtle, foreground: Style.Colors.success))
        #expect(Style.Badge.failed == .init(background: Style.Colors.dangerSubtle, foreground: Style.Colors.danger))
        #expect(Style.Badge.attention == .init(background: Style.Colors.attentionSubtle, foreground: Style.Colors.attention))
        #expect(Style.Badge.warning == .init(background: Style.Colors.warningSubtle, foreground: Style.Colors.warning))
        #expect(Style.Badge.neutral == .init(background: Style.Colors.surfaceActive, foreground: Style.Colors.textSecondary))
    }

    @Test func givenTheChipAndPaneRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.Chip.height == 24)
        #expect(Style.Chip.paddingHorizontal == 8)
        #expect(Style.Chip.gap == 4)
        #expect(Style.Chip.borderWidth == 1)
        #expect(Style.Chip.borderColor == Style.Colors.border)
        #expect(Style.Chip.cornerRadius == 999)
        #expect(Style.Chip.fontSize == 12)
        #expect(Style.Chip.color == Style.Colors.textSecondary)
        #expect(Style.Chip.hoverFill == Style.Colors.surfaceHover)
        #expect(Style.Chip.hoverColor == Style.Colors.text)

        #expect(Style.PaneHead.width == 420)
        #expect(Style.PaneHead.leadingBorderWidth == 1)
        #expect(Style.PaneHead.borderColor == Style.Colors.border)
        #expect(Style.PaneHead.fill == Style.Colors.pageBackground)
        #expect(Style.PaneHead.height == 44)
        #expect(Style.PaneHead.gap == 8)
        #expect(Style.PaneHead.paddingHorizontal == 12)
        #expect(Style.PaneHead.bottomBorderWidth == 1)
        #expect(Style.PaneHead.overlayShadow == Style.Shadows.popover)
        #expect(Style.PaneHead.overlayRing == Style.Shadows.popoverRing)

        #expect(Style.PaneTab.gap == 2)
        #expect(Style.PaneTab.height == 30)
        #expect(Style.PaneTab.paddingHorizontal == 10)
        #expect(Style.PaneTab.cornerRadius == 6)
        #expect(Style.PaneTab.fontSize == 13)
        #expect(Style.PaneTab.weight == .medium)
        #expect(Style.PaneTab.gapToCount == 6)
        #expect(Style.PaneTab.color == Style.Colors.textSecondary)
        #expect(Style.PaneTab.hoverFill == Style.Colors.surfaceHover)
        #expect(Style.PaneTab.hoverColor == Style.Colors.text)
        #expect(Style.PaneTab.activeFill == Style.Colors.surfaceActive)
        #expect(Style.PaneTab.activeColor == Style.Colors.text)
        #expect(Style.PaneTab.countSize == 12)
        #expect(Style.PaneTab.countColor == Style.Colors.textTertiary)

        #expect(Style.PaneBody.padding == 12)
        #expect(Style.PaneBody.gap == 8)
    }

    @Test func givenTheFactsRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.FactsSummary.borderWidth == 1)
        #expect(Style.FactsSummary.borderColor == Style.Colors.border)
        #expect(Style.FactsSummary.gap == 6)
        #expect(Style.FactsSummary.minHeight == 28)
        #expect(Style.FactsSummary.weight == .medium)
        #expect(Style.FactsSummary.fontSize == 13)
        #expect(Style.FactsSummary.expandedChevronDegrees == 90)

        #expect(Style.FactsBody.paddingBottom == 8)
        #expect(Style.FactsBody.paddingLeading == 20)
        #expect(Style.FactsBody.text == .init(size: 13, lineHeight: 19))
        #expect(Style.FactsBody.rowGap == 2)
        #expect(Style.FactsBody.columnGap == 10)
        #expect(Style.FactsBody.listMarginVertical == 4)
        #expect(Style.FactsBody.listText == .init(size: 12, lineHeight: 17))
        #expect(Style.FactsBody.termColor == Style.Colors.textTertiary)
        #expect(Style.FactsBody.headingMarginTop == 10)
        #expect(Style.FactsBody.headingMarginBottom == 2)
        #expect(Style.FactsBody.headingSize == 12)
        #expect(Style.FactsBody.headingWeight == .semibold)
        #expect(Style.FactsBody.headingColor == Style.Colors.textSecondary)
    }

    @Test func givenTheBannerNoticeAndResourceRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.Banner.gap == 10)
        #expect(Style.Banner.paddingVertical == 10)
        #expect(Style.Banner.paddingHorizontal == 14)
        #expect(Style.Banner.cornerRadius == 8)
        #expect(Style.Banner.text == .init(size: 13, lineHeight: 20))
        #expect(Style.Banner.color == Style.Colors.text)
        #expect(Style.Banner.danger == .init(background: Style.Colors.dangerSubtle, foreground: Style.Colors.danger))
        #expect(Style.Banner.warning == .init(background: Style.Colors.warningSubtle, foreground: Style.Colors.warning))
        #expect(Style.Banner.iconTopInset == 2)
        #expect(Style.Banner.titleWeight == .semibold)

        #expect(Style.Notice.gap == 10)
        #expect(Style.Notice.paddingVertical == 8)
        #expect(Style.Notice.paddingHorizontal == 12)
        #expect(Style.Notice.cornerRadius == 8)
        #expect(Style.Notice.fill == Style.Colors.surfaceSunken)
        #expect(Style.Notice.text == .init(size: 13, lineHeight: 19))
        #expect(Style.Notice.warning == .init(background: Style.Colors.warningSubtle, foreground: Style.Colors.warning))

        #expect(Style.ResourceCard.gap == 4)
        #expect(Style.ResourceCard.padding == 12)
        #expect(Style.ResourceCard.fontSize == 13)
        #expect(Style.ResourceCard.borderWidth == 1)
        #expect(Style.ResourceCard.borderColor == Style.Colors.border)
        #expect(Style.ResourceCard.cornerRadius == 8)
        #expect(Style.ResourceCard.fill == Style.Colors.surface)
        #expect(Style.ResourceCard.linkColor == Style.Colors.accent)
    }

    @Test func givenTheMenuRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.Menu.minWidth == 240)
        #expect(Style.Menu.maxWidth == 320)
        #expect(Style.Menu.fill == Style.Colors.surface)
        #expect(Style.Menu.cornerRadius == 12)
        #expect(Style.Menu.shadow == Style.Shadows.popover)
        #expect(Style.Menu.ring == Style.Shadows.popoverRing)
        #expect(Style.Menu.padding == 4)
        #expect(Style.Menu.gap == 1)
        #expect(Style.Menu.anchorOffset == 6)
        #expect(Style.Menu.labelPaddingTop == 6)
        #expect(Style.Menu.labelPaddingHorizontal == 10)
        #expect(Style.Menu.labelPaddingBottom == 4)
        #expect(Style.Menu.labelText == .init(size: 12, lineHeight: 16))
        #expect(Style.Menu.labelColor == Style.Colors.textTertiary)
        #expect(Style.Menu.labelWeight == .medium)
        #expect(Style.Menu.itemGap == 10)
        #expect(Style.Menu.itemMinHeight == 32)
        #expect(Style.Menu.itemPaddingVertical == 5)
        #expect(Style.Menu.itemPaddingHorizontal == 10)
        #expect(Style.Menu.itemCornerRadius == 8)
        #expect(Style.Menu.itemText == .init(size: 13, lineHeight: 18))
        #expect(Style.Menu.itemColor == Style.Colors.text)
        #expect(Style.Menu.itemHoverFill == Style.Colors.surfaceHover)
        #expect(Style.Menu.itemIconColor == Style.Colors.textSecondary)
        #expect(Style.Menu.hintText == .init(size: 12, lineHeight: 16))
        #expect(Style.Menu.hintColor == Style.Colors.textTertiary)
        #expect(Style.Menu.checkColor == Style.Colors.accent)
        #expect(Style.Menu.dangerColor == Style.Colors.danger)
        #expect(Style.Menu.disabledOpacity == 0.45)
        #expect(Style.Menu.separatorThickness == 1)
        #expect(Style.Menu.separatorColor == Style.Colors.border)
        #expect(Style.Menu.separatorMarginVertical == 4)
        #expect(Style.Menu.separatorMarginHorizontal == 6)
    }

    @Test func givenTheDialogRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.Dialog.width == 440)
        #expect(Style.Dialog.fill == Style.Colors.surface)
        #expect(Style.Dialog.cornerRadius == 12)
        #expect(Style.Dialog.shadow == Style.Shadows.dialog)
        #expect(Style.Dialog.padding == 24)
        #expect(Style.Dialog.gap == 12)
        #expect(Style.Dialog.title == .init(size: 15, lineHeight: 22))
        #expect(Style.Dialog.titleWeight == .semibold)
        #expect(Style.Dialog.text == .init(size: 13, lineHeight: 20))
        #expect(Style.Dialog.textColor == Style.Colors.textSecondary)
        #expect(Style.Dialog.actionsGap == 8)
        #expect(Style.Dialog.actionsMarginTop == 8)
        #expect(Style.Dialog.scrimFill == Style.Colors.pageBackground)
        #expect(Style.Dialog.scrimOpacity == 0.55)
    }

    @Test func givenTheChangeRowRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.ChangeRow.gap == 8)
        #expect(Style.ChangeRow.height == 32)
        #expect(Style.ChangeRow.paddingHorizontal == 12)
        #expect(Style.ChangeRow.fontSize == 13)
        #expect(Style.ChangeRow.cornerRadius == 6)
        #expect(Style.ChangeRow.hoverFill == Style.Colors.surfaceHover)
        #expect(Style.ChangeRow.compactHeight == 28)
        #expect(Style.ChangeRow.compactPaddingHorizontal == 6)
        #expect(Style.ChangeRow.selectedFill == Style.Colors.surfaceActive)
        #expect(Style.ChangeRow.dimOpacity == 0.7)
        #expect(Style.ChangeRow.pathSize == 12)
        #expect(Style.ChangeRow.countSize == 12)
        #expect(Style.ChangeRow.addColor == Style.Colors.success)
        #expect(Style.ChangeRow.deleteColor == Style.Colors.danger)
        #expect(Style.ChangeRow.statusWidth == 14)
        #expect(Style.ChangeRow.statusSize == 11)
        #expect(Style.ChangeRow.statusWeight == .semibold)
        #expect(Style.ChangeRow.statusColor == Style.Colors.textTertiary)
        #expect(Style.ChangeRow.statusAdded == Style.Colors.success)
        #expect(Style.ChangeRow.statusDeleted == Style.Colors.danger)
        #expect(Style.ChangeRow.statusModified == Style.Colors.attention)
        #expect(Style.ChangeRow.statusUnmerged == Style.Colors.danger)
        #expect(Style.ChangeRow.rowStateMaxWidth == 150)
        #expect(Style.ChangeRow.rowStateSize == 11)
        #expect(Style.ChangeRow.rowStateColor == Style.Colors.textTertiary)
    }

    @Test func givenTheTagDiffAndDerivedRules_whenReadingMetrics_thenTheyMatchTheDesign() {
        // given / when / then
        #expect(Style.ChangeTag.height == 18)
        #expect(Style.ChangeTag.paddingHorizontal == 6)
        #expect(Style.ChangeTag.cornerRadius == 6)
        #expect(Style.ChangeTag.fontSize == 11)
        #expect(Style.ChangeTag.weight == .medium)
        #expect(Style.ChangeTag.base == .init(background: Style.Colors.surfaceActive, foreground: Style.Colors.textSecondary))
        #expect(Style.ChangeTag.warn == .init(background: Style.Colors.warningSubtle, foreground: Style.Colors.warning))
        #expect(Style.ChangeTag.ok == .init(background: Style.Colors.successSubtle, foreground: Style.Colors.success))
        #expect(Style.ChangeTag.info == .init(background: Style.Colors.accentSubtle, foreground: Style.Colors.accent))

        #expect(Style.Diff.text == .init(size: 12, lineHeight: 19))
        #expect(Style.Diff.borderWidth == 1)
        #expect(Style.Diff.borderColor == Style.Colors.border)
        #expect(Style.Diff.cornerRadius == 8)
        #expect(Style.Diff.fill == Style.Colors.surface)
        #expect(Style.Diff.linePaddingHorizontal == 10)
        #expect(Style.Diff.addFill == Style.Colors.diffAdd)
        #expect(Style.Diff.deleteFill == Style.Colors.diffRemove)
        #expect(Style.Diff.hunkColor == Style.Colors.textTertiary)
        #expect(Style.Diff.hunkFill == Style.Colors.surfaceSunken)
        #expect(Style.Diff.signWidth == 14)
        #expect(Style.Diff.signColor == Style.Colors.textTertiary)

        #expect(Style.DerivedBox.paddingVertical == 8)
        #expect(Style.DerivedBox.paddingHorizontal == 10)
        #expect(Style.DerivedBox.fill == Style.Colors.surfaceSunken)
        #expect(Style.DerivedBox.cornerRadius == 6)
        #expect(Style.DerivedBox.text == .init(size: 13, lineHeight: 19))
        #expect(Style.DerivedBox.paragraphMarginVertical == 2)
    }
}
