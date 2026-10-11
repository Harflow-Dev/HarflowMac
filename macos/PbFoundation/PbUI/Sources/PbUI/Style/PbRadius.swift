import SwiftUI

// MARK: - PbRadius

/// The Monitor's corner radii and design-derived component dimensions (SPEC §3/§5). Views pick a
/// radius or a metric from here instead of writing a numeric size literal, so a dimension change
/// happens in one place.
public enum PbRadius {
    /// Cards, stat tiles, node cards, activity cards.
    public static let card: CGFloat = 12
    /// List rows, selection highlights, grouped-row containers' inner rows.
    public static let row: CGFloat = 8
    /// Buttons and fields.
    public static let button: CGFloat = 8
    /// Inspector, canvas frame, lane cards, sheets' panels.
    public static let panel: CGFloat = 16
    /// Sheets.
    public static let sheet: CGFloat = 20

    /// Shared component dimensions the design derives once: heights, paddings, glyph sizes and
    /// strokes. Component and screen dimensions belong in named tokens, never view literals.
    public enum Metrics {
        /// Foundation diagnostics and component preview canvases.
        public static let foundationWidth: CGFloat = 1000
        public static let foundationHeight: CGFloat = 780
        public static let foundationPixelWidth = 2000
        public static let foundationPixelHeight = 1560
        public static let foundationSampleStride = 17
        public static let activityPreviewWidth: CGFloat = 320
        public static let formPreviewWidth: CGFloat = 300
        public static let toolbarPreviewWidth: CGFloat = 900
        public static let toolbarPreviewHeight: CGFloat = 500
        /// Shared layout steps, including unpadded compositional containers.
        public static let zero: CGFloat = 0
        public static let spacing2: CGFloat = 2
        public static let spacing4: CGFloat = 4
        public static let spacing5: CGFloat = 5
        public static let spacing6: CGFloat = 6
        public static let spacing8: CGFloat = 8
        public static let spacing10: CGFloat = 10
        public static let spacing12: CGFloat = 12
        public static let spacing14: CGFloat = 14
        public static let spacing16: CGFloat = 16
        public static let spacing20: CGFloat = 20
        public static let spacing24: CGFloat = 24
        public static let spacing28: CGFloat = 28
        /// Compact native form-control button target and value width.
        public static let compactControlHeight: CGFloat = 24
        public static let compactValueWidth: CGFloat = 28
        /// The standalone spinner's size and ring width.
        public static let spinnerSize: CGFloat = 14
        public static let spinnerStroke: CGFloat = 2
        /// The status badge capsule (§5.1): its height, horizontal padding and icon glyph.
        public static let badgeHeight: CGFloat = 24
        public static let badgeHorizontalPadding: CGFloat = 10
        public static let badgeGlyphSize: CGFloat = 12
        /// The sidebar status icon's square frame (§5.1).
        public static let statusIconSize: CGFloat = 16
        /// Primary and tinted buttons (§5.3): capsule height and horizontal paddings.
        public static let primaryButtonHeight: CGFloat = 30
        public static let primaryButtonHorizontalPadding: CGFloat = 16
        public static let secondaryButtonHorizontalPadding: CGFloat = 14
        /// Grouped form rows (§5.5): container radius, row height and horizontal paddings.
        public static let formRadius: CGFloat = 10
        public static let formRowHeight: CGFloat = 36
        public static let formRowLeadingPadding: CGFloat = 12
        public static let formRowTrailingPadding: CGFloat = 10
        /// Activity cards (§5.4): padded-card and row paddings, the row icon's glyph, hairlines.
        public static let cardPaddingVertical: CGFloat = 10
        public static let cardPaddingHorizontal: CGFloat = 14
        public static let activityRowPaddingVertical: CGFloat = 10
        public static let activityRowPaddingHorizontal: CGFloat = 14
        public static let activityIconSize: CGFloat = 15
        public static let hairlineStroke: CGFloat = 1
        /// The sliding segmented control (§5.6): track/thumb radii, height and the thumb's shadow.
        public static let segmentedTrackRadius: CGFloat = 10
        public static let segmentedThumbRadius: CGFloat = 7
        public static let segmentedHeight: CGFloat = 32
        public static let segmentedShadowRadius: CGFloat = 1
        /// The backend identity dot and its overlapping stack (§5.2).
        public static let backendDotSize: CGFloat = 8
        public static let backendDotStackSize: CGFloat = 10
        public static let backendDotStackOverlap: CGFloat = 0.3
        public static let backendDotStackStroke: CGFloat = 1.5
        /// The shared row's own geometry (§6.1's consumers keep it as their default): the
        /// vertical padding, the title-to-meta gap, the item gap, the chevron's square frame and
        /// the tree gutter's default column.
        public static let rowPaddingVertical: CGFloat = 6
        public static let rowLineSpacing: CGFloat = 3
        public static let rowItemSpacing: CGFloat = 8
        public static let rowChevronFrame: CGFloat = 16
        public static let treeGutterColumnWidth: CGFloat = 16
        /// The sidebar's own row treatment (§6.1): the 15 pt status glyph frame, the 7 pt row
        /// padding over the 8 pt row insets, the 20 pt child-guide column, the filter's compact
        /// dots, the group's 3 pt progress strip and the footer's connection dot.
        public static let sidebarStatusIconSize: CGFloat = 15
        public static let sidebarRowPaddingVertical: CGFloat = 7
        public static let sidebarRowInsetHorizontal: CGFloat = 8
        public static let sidebarChildGuideWidth: CGFloat = 20
        public static let sidebarFilterDotSize: CGFloat = 7
        public static let sidebarProgressHeight: CGFloat = 3
        public static let sidebarConnectionDotSize: CGFloat = 7
        /// Sidebar control adaptation and preview canvases.
        public static let sidebarSearchMinimumWidth: CGFloat = 120
        public static let sidebarPreviewWidth: CGFloat = 272
        public static let sidebarPreviewHeight: CGFloat = 600
        public static let sidebarCompactPreviewHeight: CGFloat = 400
        public static let sidebarHistoryMinimumHeight: CGFloat = 20
        public static let groupPreviewWidth: CGFloat = 280
        public static let sidebarTallFixtureHeight: CGFloat = 800
        /// Task detail (§6.2): the content column's max width, which already includes the 24 pt
        /// inner padding on each side (712 pt usable), and the screen's preview canvases.
        public static let taskColumnMaxWidth: CGFloat = 760
        public static let taskDetailPreviewWidth: CGFloat = 1000
        public static let taskDetailPreviewHeight: CGFloat = 620
        public static let taskDetailNarrowPreviewWidth: CGFloat = 480
        public static let taskDetailNarrowPreviewHeight: CGFloat = 700
        /// Production task inspector width, independent of sidebar previews.
        public static let taskInspectorWidth: CGFloat = 280
        /// The message composer's glass capsule (§6.2) and its circular send button.
        public static let composerCornerRadius: CGFloat = 18
        public static let composerSendButtonSize: CGFloat = 32
        /// The prompt bubble (§6.2): 14 pt corners with the tail-side corner at 4 pt.
        public static let promptBubbleCornerRadius: CGFloat = 14
        public static let promptBubbleTailCornerRadius: CGFloat = 4
        /// Summary stat tiles (§6.2): the tile's fixed width and the row's gap.
        public static let summaryTileWidth: CGFloat = 160
        public static let summaryTileSpacing: CGFloat = 10
        /// Prompt alignment and Summary status icon emphasis.
        public static let promptBubbleLeadingSpace: CGFloat = 48
        public static let summaryStatusIconScale: CGFloat = 1.6
        /// Loading activity's representative file-pill widths, independent of real task data.
        public static let taskSkeletonPillWidths: [CGFloat] = [96, 140, 118, 80]
        /// Task activity, Summary and loading presentation dimensions, retained from their views.
        public static let taskSkeletonLineSpacing: CGFloat = 9
        public static let taskSkeletonCaptionHeight: CGFloat = 11
        public static let taskSkeletonBodyHeight: CGFloat = 13
        public static let taskSkeletonPillHeight: CGFloat = 22
        public static let taskSkeletonDetailInset: CGFloat = 26
        public static let taskSkeletonResultWidth: CGFloat = 72
        public static let taskSkeletonActionWidth: CGFloat = 84
        public static let taskSkeletonShortLineWidth: CGFloat = 90
        public static let taskSkeletonStatusWidth: CGFloat = 110
        public static let taskSkeletonTitleWidth: CGFloat = 140
        public static let taskSkeletonLongTitleWidth: CGFloat = 170
        public static let taskSkeletonHeadingWidth: CGFloat = 220
        public static let taskSkeletonComposerWidth: CGFloat = 240
        public static let taskSkeletonStartWidth: CGFloat = 260
        public static let toolRowPreviewWidth: CGFloat = 420
        public static let timelineRowPreviewWidth: CGFloat = 440
        public static let taskSkeletonPromptWidth: CGFloat = 460
        public static let summaryPreviewWidth: CGFloat = 520
        /// Summary preview canvas height, independent of component preview widths.
        public static let summaryPreviewHeight: CGFloat = 560
        /// Loading task geometry: heading height, feed rhythm, expanded title bar and toolbar blocks.
        public static let taskSkeletonHeadingHeight: CGFloat = 18
        public static let taskSkeletonFeedSpacing: CGFloat = 18
        public static let taskSkeletonExpandedTitleWidth: CGFloat = 120
        public static let taskSkeletonToolbarButtonWidth: CGFloat = 30
        public static let taskSkeletonToolbarBlockRadius: CGFloat = 7
        public static let taskComponentPreviewWidth: CGFloat = 560
        public static let timelinePanePreviewWidth: CGFloat = 640
        /// Workflow editor and run (§6.3/§6.4): the measured node, canvas, panel and control
        /// geometry. These are the existing contracts, named so no view writes the literal.
        public static let workflowNodeSize = CGSize(width: 200, height: 92)
        public static let workflowCompactNodeSize = CGSize(width: 72, height: 72)
        public static let workflowParallelBoundarySize = CGSize(width: 110, height: 72)
        public static let workflowSnapSpacing: CGFloat = 10
        public static let workflowGridDotDiameter: CGFloat = 1.7
        public static let workflowGridMinimumScreenSpacing: CGFloat = 20
        public static let workflowPortOuterRadius: CGFloat = 5.25
        public static let workflowPortHighlightRadius: CGFloat = 6.75
        public static let workflowCanvasInset: CGFloat = 16
        public static let workflowUnsavedDotSize: CGFloat = 6
        /// Node card (§6.3): padding, the 24 pt role tile, selection stroke and ring, shadows.
        public static let workflowNodePadding: CGFloat = 12
        public static let workflowNodeIconTileSize: CGFloat = 24
        public static let workflowNodeIconTileCornerRadius: CGFloat = 7
        public static let workflowNodeSelectedBorderWidth: CGFloat = 1.5
        public static let workflowNodeAttentionBorderWidth: CGFloat = 1.5
        public static let workflowNodeRingWidth: CGFloat = 4
        public static let workflowNodeRingInset: CGFloat = 2
        public static let workflowNodePendingOpacity: CGFloat = 0.75
        public static let workflowNodeShadowNearY: CGFloat = 1
        public static let workflowNodeShadowNearRadius: CGFloat = 2
        public static let workflowNodeShadowNearOpacity: CGFloat = 0.05
        public static let workflowNodeShadowFarY: CGFloat = 6
        public static let workflowNodeShadowFarRadius: CGFloat = 20
        public static let workflowNodeShadowFarOpacity: CGFloat = 0.06
        /// Connections: stroke widths, the arrowhead, hit slop and the condition pill.
        public static let workflowConnectionLineWidth: CGFloat = 1.5
        public static let workflowConnectionHighlightedLineWidth: CGFloat = 2
        public static let workflowArrowheadLength: CGFloat = 7
        public static let workflowArrowheadHalfWidth: CGFloat = 5
        public static let workflowConnectionHitWidth: CGFloat = 18
        public static let workflowConditionPillHorizontalPadding: CGFloat = 9
        public static let workflowConditionPillVerticalPadding: CGFloat = 4
        public static let workflowConditionPillOffset: CGFloat = 16
        public static let workflowConditionPillMaximumWidth: CGFloat = 160
        /// The floating glass step tray, its divider and the zoom capsule.
        public static let workflowTrayCornerRadius: CGFloat = 14
        public static let workflowTrayPadding: CGFloat = 4
        public static let workflowTrayDividerHeight: CGFloat = 18
        public static let workflowZoomPadding: CGFloat = 6
        public static let workflowZoomSymbolSize = CGSize(width: 14, height: 18)
        public static let workflowZoomResetWidth: CGFloat = 44
        public static let workflowZoomInset: CGFloat = 12
        /// The inline glass header group's ellipsis menu target and its hairline separator.
        public static let workflowHeaderMenuWidth: CGFloat = 30
        public static let workflowHeaderDividerHeight: CGFloat = 16
        /// Inspector and run panel widths: initial 288 (§6.3/§6.4), the unchanged clamps and
        /// the canvas minimum the native split defends.
        public static let workflowInspectorInitialWidth: CGFloat = 288
        public static let workflowInspectorMinimumWidth: CGFloat = 220
        public static let workflowInspectorMaximumWidth: CGFloat = 500
        public static let workflowCanvasMinimumWidth: CGFloat = 400
        public static let workflowRunCanvasMinimumHeight: CGFloat = 170
        public static let workflowRunCanvasIdealHeight: CGFloat = 300
        public static let workflowRunActivityMinimumHeight: CGFloat = 240
        public static let workflowRunPanelMinimumWidth: CGFloat = 220
        public static let workflowRunPanelIdealWidth: CGFloat = 288
        public static let workflowRunPanelMaximumWidth: CGFloat = 500
        /// The run plan checklist's 4 pt progress strip.
        public static let workflowPlanProgressHeight: CGFloat = 4
        /// The needs-attention recovery banner (§6.4): radius, padding and the compact
        /// growing multiline editor's two-line minimum and 100 pt maximum.
        public static let recoveryBannerCornerRadius: CGFloat = 14
        public static let recoveryBannerPadding: CGFloat = 14
        public static let recoveryEditorMinimumHeight: CGFloat = 56
        public static let recoveryEditorMaximumHeight: CGFloat = 100
        /// The non-blocking floating recovery panel (user amendment over §6.4): its adaptive
        /// ideal width and pane-edge insets, the close control's square target, and the
        /// floating elevation's shadow radius, offset and ink strength.
        public static let recoveryPanelIdealWidth: CGFloat = 400
        /// Initial measurement bound before the floating recovery form's first layout.
        public static let recoveryPanelInitialHeight: CGFloat = 320
        /// Inset from the pane's top and trailing edges.
        public static let recoveryPanelInset: CGFloat = 12
        /// Square target of the recovery panel's explicit close control.
        public static let recoveryCloseTarget: CGFloat = 24
        /// Recovery panel elevation blur radius.
        public static let recoveryPanelShadowRadius: CGFloat = 16
        /// Recovery panel elevation's vertical offset.
        public static let recoveryPanelShadowOffsetY: CGFloat = 6
        /// Workflow preview canvases.
        public static let workflowPreviewWidth: CGFloat = 1200
        public static let workflowPreviewHeight: CGFloat = 700
        public static let workflowNarrowPreviewWidth: CGFloat = 480
        /// Retained workflow fields, loading shapes, port targets and component preview sizes.
        public static let workflowPortDiameter: CGFloat = 9
        public static let workflowLoadingStatusHeight: CGFloat = 27
        public static let workflowNodePreviewInset: CGFloat = 40
        public static let workflowLoadingSpacer: CGFloat = 60
        public static let workflowLoadingCompactNodeSize: CGFloat = 64
        public static let workflowFieldValueWidth: CGFloat = 80
        public static let workflowLoadingNodeHeight: CGFloat = 86
        public static let workflowLoadingNodeWidth: CGFloat = 130
        public static let workflowCanvasPreviewHeight: CGFloat = 360
        public static let workflowLoadingGraphWidth: CGFloat = 508
        public static let workflowInspectorPreviewHeight: CGFloat = 650
        public static let workflowLoadingTitleWidth: CGFloat = 75
        public static let workflowLoadingMetaWidth: CGFloat = 45
        public static let workflowLoadingConnectorMidpoint: CGFloat = 43
        public static let workflowLoadingConnectorTip: CGFloat = 37.5
        public static let workflowLoadingConnectorWing: CGFloat = 31.5
        public static let workflowLoadingConnectorUpperY: CGFloat = 37
        public static let workflowLoadingConnectorLowerY: CGFloat = 49
        public static let workflowConnectionDash: [CGFloat] = [5, 3]
        public static let workflowPendingDash: [CGFloat] = [4, 3]
        public static let workflowTooltipMaximumWidth: CGFloat = 240
        public static let workflowTooltipHorizontalClearance: CGFloat = 36
        public static let workflowTooltipVerticalClearance: CGFloat = 16
        public static let workflowDiagnosticsMaximumHeight: CGFloat = 180
        public static let workflowLaunchSheetWidth: CGFloat = 580
        public static let workflowLaunchSheetHeight: CGFloat = 650
        /// Parallel lanes (§6.5): the 3 pt status strip across a lane card's top edge.
        public static let parallelLaneStatusStripHeight: CGFloat = 3
        /// Maximum height of a settled lane's independently scrollable result callout.
        public static let parallelResultMaximumHeight: CGFloat = 160
        /// Width of the Parallel screen's deferred title skeleton.
        public static let parallelSkeletonTitleWidth: CGFloat = 180
        /// Height of the Parallel screen's deferred title skeleton.
        public static let parallelSkeletonTitleHeight: CGFloat = 18
        /// Width of the Parallel screen's deferred metadata skeleton.
        public static let parallelSkeletonMetaWidth: CGFloat = 260
        /// Square avatar placeholder inside a deferred lane.
        public static let parallelSkeletonAvatarSize: CGFloat = 22
        /// Corner radius of the deferred lane's avatar placeholder.
        public static let parallelSkeletonAvatarRadius: CGFloat = 11
        /// Width of the deferred lane's title placeholder.
        public static let parallelSkeletonColumnTitleWidth: CGFloat = 160
        /// Width of the deferred lane's metadata placeholder.
        public static let parallelSkeletonColumnMetaWidth: CGFloat = 100
        /// Width of a standalone lane content preview.
        public static let parallelColumnPreviewWidth: CGFloat = 380
        /// Height of a standalone lane content preview.
        public static let parallelColumnPreviewHeight: CGFloat = 560
        /// The Parallel claim pills' capsule padding, paired with the status badge metrics.
        public static let parallelPillHorizontalPadding: CGFloat = 8
        /// Vertical inset of the Parallel claim pills.
        public static let parallelPillVerticalPadding: CGFloat = 4
        /// The live indicator's three-dot variant (§6.5): dot size and the gap between dots.
        public static let liveIndicatorDotSize: CGFloat = 4
        /// Gap between native presentation dots in the live indicator.
        public static let liveIndicatorDotSpacing: CGFloat = 3
        /// New session (§6.6): the sheet's own width, its prompt editor, the focus ring's
        /// 1.5 pt accent stroke with its 4 pt running-tint glow, and the minimum card widths the
        /// adaptive agent/access grids wrap at (5 agent cards per row at 760; 2×2 access cards).
        public static let newSessionSheetWidth: CGFloat = 760
        /// Height of the New session task editor.
        public static let newSessionPromptEditorHeight: CGFloat = 112
        /// Stroke width of the focused task editor.
        public static let newSessionPromptFocusBorderWidth: CGFloat = 1.5
        /// Radius of the focused task editor's running-tint glow.
        public static let newSessionPromptFocusGlowRadius: CGFloat = 4
        /// Selected agent and requested-access card border width.
        public static let newSessionCardSelectedBorderWidth: CGFloat = 1.5
        /// Minimum agent card width before the catalog wraps.
        public static let newSessionAgentCardMinimumWidth: CGFloat = 128
        /// Minimum requested-access card width before options wrap.
        public static let newSessionAccessCardMinimumWidth: CGFloat = 300
        /// Retained sheet height clamps and the access radio's selected ring.
        public static let newSessionIdealHeight: CGFloat = 860
        /// Retained minimum height of the New session sheet.
        public static let newSessionMinimumHeight: CGFloat = 420
        /// Retained maximum height of the New session sheet.
        public static let newSessionMaximumHeight: CGFloat = 920
        /// Retained selected access radio ring width.
        public static let accessRadioSelectedStroke: CGFloat = 5
        /// Retained unselected requested-access radio ring width.
        public static let accessRadioUnselectedStroke: CGFloat = 1.5
        /// Retained width of the Advanced effort and turn-limit fields.
        public static let newSessionAdvancedFieldWidth: CGFloat = 160
        /// Retained inset of the Advanced options grid.
        public static let newSessionAdvancedLeadingInset: CGFloat = 15
        /// Existing prompt placeholder inset and expanded disclosure angle.
        public static let newSessionPromptPlaceholderInset: CGFloat = 13
        /// Rotation in degrees of the expanded Advanced disclosure.
        public static let newSessionDisclosureAngle: Double = 90
        /// Settings (§6.7): the content column's maximum width, centred near the top.
        public static let settingsContentMaxWidth: CGFloat = 560
        /// Retained width of the MCP allowlist sheet.
        public static let mcpAllowlistSheetWidth: CGFloat = 590
        /// Retained native Settings scene width and allowlist scroll-area minimum.
        public static let settingsSceneWidth: CGFloat = 620
        /// Retained height of the native Settings scene.
        public static let settingsSceneHeight: CGFloat = 460
        /// Retained minimum height of the allowlist scrolling area.
        public static let mcpAllowlistMinimumHeight: CGFloat = 150
        /// Retained maximum height of the allowlist scrolling area.
        public static let mcpAllowlistMaximumHeight: CGFloat = 260
        /// Menu bar: the status item's item gap, the header's compact icon targets and the
        /// running row's second-line inset under its 16 pt status glyph.
        public static let menuBarItemSpacing: CGFloat = 3
        /// Compact header icon button's square target.
        public static let menuBarIconButtonFrame: CGFloat = 24
        /// Settings gear's square target in the popover.
        public static let menuBarGearIconFrame: CGFloat = 20
        /// Detail inset beneath the running row's status glyph.
        public static let menuBarRunningRowDetailInset: CGFloat = 24
        /// The menu-bar footer's primary button and gear target height (§6.8).
        public static let menuBarFooterButtonHeight: CGFloat = 34
        /// The existing popover width, independent of its displayed task counts.
        public static let menuBarPopoverWidth: CGFloat = 380
        /// Retained height of the menu-bar popover.
        public static let menuBarPopoverHeight: CGFloat = 560
    }
}
