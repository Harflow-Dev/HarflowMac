//
//  TaskLoadingSkeleton.swift
//  MainWindowFeature
//
//  The task screen while its data is still arriving (the design's "Task loading — shimmer"
//  artboards). It mirrors the loaded layout block for block — content header, the toolbar's four
//  native items and their glass grouping, tab switcher, the 760 pt reading column, the composer —
//  so nothing jumps when the content replaces it.
//

import HfUI
import SwiftUI

// MARK: - TaskLoadingHeader

/// What the skeleton already knows about the task: shown for real instead of bars.
struct TaskLoadingHeader: Equatable {
    let title: String
    let repoName: String
}

// MARK: - TaskLoadingSkeleton

struct TaskLoadingSkeleton: View {
    let header: TaskLoadingHeader?
    var isEmbedded = false

    var body: some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            title
                .padding(.horizontal, isEmbedded ? HfRadius.Metrics.spacing16 : HfRadius.Metrics.spacing24)
                .padding(.top, HfRadius.Metrics.spacing12)
            SlidingSegmentedControl(options: TaskTab.allCases.map { ($0, $0.rawValue) }, selection: .constant(.activity))
                .disabled(true)
                .opacity(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, isEmbedded ? HfRadius.Metrics.spacing16 : HfRadius.Metrics.spacing24)
                .padding(.top, isEmbedded ? HfRadius.Metrics.spacing8 : HfRadius.Metrics.spacing16)
                .padding(.bottom, isEmbedded ? HfRadius.Metrics.spacing8 : HfRadius.Metrics.spacing16)
            ScrollView {
                feed
                    .padding(.horizontal, HfRadius.Metrics.spacing24)
                    .padding(.top, HfRadius.Metrics.spacing12)
                    .readingColumn()
                    // The document probe (§6.2): inside the skeleton feed's own document.
                    .background(ScrollChrome())
            }
            .frame(minHeight: HfRadius.Metrics.zero, maxHeight: .infinity, alignment: .top)
            composer
                .padding(.horizontal, HfRadius.Metrics.spacing24)
                .padding(.bottom, HfRadius.Metrics.spacing20)
                .readingColumn()
        }
        .background(Color.windowBG)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading task")
        .modifier(LoadingToolbar(isEmbedded: isEmbedded))
    }

    @ViewBuilder
    private var title: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            if let header {
                Text(header.title)
                    .font(.hf(.title, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(header.title)
                Text(header.repoName).font(.hf(.secondary)).foregroundStyle(Color.secondaryText).lineLimit(1)
            } else {
                SkeletonBlock(width: HfRadius.Metrics.taskSkeletonHeadingWidth, height: HfRadius.Metrics.taskSkeletonHeadingHeight)
                SkeletonBlock(width: HfRadius.Metrics.taskSkeletonShortLineWidth, height: HfRadius.Metrics.spacing12)
            }
        }
        .frame(minWidth: HfRadius.Metrics.zero, maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    // MARK: Feed

    private var feed: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.taskSkeletonFeedSpacing) {
            promptBubble
            HStack(spacing: HfRadius.Metrics.spacing8) {
                SkeletonBlock(width: HfRadius.Metrics.spacing8, height: HfRadius.Metrics.spacing8, cornerRadius: HfRadius.Metrics.spacing4)
                SkeletonBlock(width: HfRadius.Metrics.taskSkeletonStartWidth, height: HfRadius.Metrics.taskSkeletonCaptionHeight)
            }
            collapsedCard(titleWidth: HfRadius.Metrics.taskSkeletonTitleWidth)
            VStack(alignment: .leading, spacing: HfRadius.Metrics.taskSkeletonLineSpacing) {
                fractionBar(0.96, height: HfRadius.Metrics.taskSkeletonBodyHeight)
                fractionBar(0.70, height: HfRadius.Metrics.taskSkeletonBodyHeight)
            }
            .padding(.vertical, HfRadius.Metrics.spacing2)
            expandedCard
            collapsedCard(titleWidth: HfRadius.Metrics.taskSkeletonLongTitleWidth).opacity(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptBubble: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            fractionBar(1, height: HfRadius.Metrics.spacing12)
            fractionBar(0.88, height: HfRadius.Metrics.spacing12)
            fractionBar(0.52, height: HfRadius.Metrics.spacing12)
        }
        .padding(HfRadius.Metrics.spacing14)
        .frame(width: HfRadius.Metrics.taskSkeletonPromptWidth)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: HfRadius.Metrics.promptBubbleCornerRadius,
                bottomLeadingRadius: HfRadius.Metrics.promptBubbleCornerRadius,
                bottomTrailingRadius: HfRadius.Metrics.promptBubbleTailCornerRadius,
                topTrailingRadius: HfRadius.Metrics.promptBubbleCornerRadius
            )
            .fill(Color.promptBubble)
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func collapsedCard(titleWidth: CGFloat) -> some View {
        ActivityCard {
            HStack(spacing: HfRadius.Metrics.spacing10) {
                SkeletonBlock(width: HfRadius.Metrics.spacing16, height: HfRadius.Metrics.spacing16, cornerRadius: HfRadius.Metrics.spacing4)
                SkeletonBlock(width: titleWidth, height: HfRadius.Metrics.spacing12)
                Spacer(minLength: HfRadius.Metrics.zero)
                SkeletonBlock(width: HfRadius.Metrics.taskSkeletonResultWidth, height: HfRadius.Metrics.spacing10)
            }
        }
    }

    private var expandedCard: some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                HStack(spacing: HfRadius.Metrics.spacing10) {
                    SkeletonBlock(width: HfRadius.Metrics.spacing16, height: HfRadius.Metrics.spacing16, cornerRadius: HfRadius.Metrics.spacing4)
                    SkeletonBlock(width: HfRadius.Metrics.taskSkeletonExpandedTitleWidth, height: HfRadius.Metrics.spacing12)
                    Spacer(minLength: HfRadius.Metrics.zero)
                    SkeletonBlock(width: HfRadius.Metrics.taskSkeletonShortLineWidth, height: HfRadius.Metrics.spacing10)
                }
                HStack(spacing: HfRadius.Metrics.spacing6) {
                    ForEach(HfRadius.Metrics.taskSkeletonPillWidths, id: \.self) { SkeletonBlock(width: $0, height: HfRadius.Metrics.taskSkeletonPillHeight) }
                }
                .padding(.leading, HfRadius.Metrics.taskSkeletonDetailInset)
            }
        }
    }

    /// A bar `fraction` of the available width, for lines of text whose length isn't known.
    private func fractionBar(_ fraction: CGFloat, height: CGFloat) -> some View {
        GeometryReader { proxy in
            SkeletonBlock(width: proxy.size.width * fraction, height: height)
        }
        .frame(height: height)
    }

    // MARK: Composer

    /// Mirrors the loaded composer: a rounded-18 glass capsule with a circular 32 pt send button.
    private var composer: some View {
        HStack(spacing: HfRadius.Metrics.spacing10) {
            SkeletonBlock(width: HfRadius.Metrics.taskSkeletonComposerWidth, height: HfRadius.Metrics.spacing12)
            Spacer(minLength: HfRadius.Metrics.zero)
            SkeletonBlock(
                width: HfRadius.Metrics.composerSendButtonSize,
                height: HfRadius.Metrics.composerSendButtonSize,
                cornerRadius: HfRadius.Metrics.composerSendButtonSize / 2
            )
        }
        .padding(.leading, HfRadius.Metrics.spacing16)
        .padding(.trailing, HfRadius.Metrics.spacing16)
        .padding(.vertical, HfRadius.Metrics.spacing12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: HfRadius.Metrics.composerCornerRadius))
    }
}

// MARK: - LoadingToolbar

/// Shimmer blocks where the status, primary button and the two icon buttons will be, mirroring the
/// loaded toolbar's item ids and glass grouping: the status skeleton keeps its background hidden
/// behind a fixed spacer, and the takeover/more/inspector skeletons share the SDK's one glass
/// capsule. Embedded details keep these inside their own pane instead of changing the window
/// toolbar.
private struct LoadingToolbar: ViewModifier {
    let isEmbedded: Bool

    func body(content: Content) -> some View {
        if isEmbedded {
            VStack(spacing: HfRadius.Metrics.zero) {
                HStack {
                    Spacer(minLength: HfRadius.Metrics.zero)
                    actions
                }
                .padding(.horizontal, HfRadius.Metrics.spacing16)
                .padding(.vertical, HfRadius.Metrics.spacing10)
                Divider()
                content
            }
        } else {
            content.toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem(id: "task-detail.status", placement: .primaryAction) { statusBlock }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed)
                ToolbarItem(id: "task-detail.takeover", placement: .primaryAction) { takeoverBlock }
                ToolbarItem(id: "task-detail.more", placement: .primaryAction) { moreBlock }
                ToolbarItem(id: "task-detail.inspector", placement: .primaryAction) { inspectorBlock }
            }
        }
    }

    private var statusBlock: some View {
        SkeletonBlock(width: HfRadius.Metrics.taskSkeletonStatusWidth, height: HfRadius.Metrics.spacing14,
                      cornerRadius: HfRadius.Metrics.taskSkeletonToolbarBlockRadius)
            .accessibilityHidden(true)
    }

    private var takeoverBlock: some View {
        SkeletonBlock(width: HfRadius.Metrics.taskSkeletonActionWidth, height: HfRadius.Metrics.spacing28,
                      cornerRadius: HfRadius.Metrics.taskSkeletonToolbarBlockRadius)
            .accessibilityHidden(true)
    }

    private var moreBlock: some View {
        SkeletonBlock(width: HfRadius.Metrics.taskSkeletonToolbarButtonWidth, height: HfRadius.Metrics.spacing28,
                      cornerRadius: HfRadius.Metrics.taskSkeletonToolbarBlockRadius)
            .accessibilityHidden(true)
    }

    private var inspectorBlock: some View {
        SkeletonBlock(width: HfRadius.Metrics.taskSkeletonToolbarButtonWidth, height: HfRadius.Metrics.spacing28,
                      cornerRadius: HfRadius.Metrics.taskSkeletonToolbarBlockRadius)
            .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            SkeletonBlock(width: HfRadius.Metrics.taskSkeletonStatusWidth, height: HfRadius.Metrics.spacing14,
                          cornerRadius: HfRadius.Metrics.taskSkeletonToolbarBlockRadius)
            SkeletonBlock(width: HfRadius.Metrics.taskSkeletonActionWidth, height: HfRadius.Metrics.spacing28,
                          cornerRadius: HfRadius.Metrics.taskSkeletonToolbarBlockRadius)
            SkeletonBlock(width: HfRadius.Metrics.taskSkeletonToolbarButtonWidth, height: HfRadius.Metrics.spacing28,
                          cornerRadius: HfRadius.Metrics.taskSkeletonToolbarBlockRadius)
            SkeletonBlock(width: HfRadius.Metrics.taskSkeletonToolbarButtonWidth, height: HfRadius.Metrics.spacing28,
                          cornerRadius: HfRadius.Metrics.taskSkeletonToolbarBlockRadius)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
@MainActor
private func skeletonPreview(_ header: TaskLoadingHeader?) -> some View {
    NavigationStack { TaskLoadingSkeleton(header: header) }
        .frame(width: HfRadius.Metrics.taskDetailPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
}

#Preview("Loading, long title - narrow") {
    NavigationStack {
        TaskLoadingSkeleton(header: TaskLoadingHeader(
            title: "Investigate the intermittent authentication failure and repair the session refresh flow across all application entry points",
            repoName: "repo"
        ))
    }
    .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
}

#Preview("Loading, unbroken title - embedded") {
    TaskLoadingSkeleton(
        header: TaskLoadingHeader(title: String(repeating: "LongUnbrokenTaskIdentifier", count: 8), repoName: "repo"),
        isEmbedded: true
    )
    .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("Loading, unbroken title - embedded dark") {
    TaskLoadingSkeleton(
        header: TaskLoadingHeader(title: String(repeating: "LongUnbrokenTaskIdentifier", count: 8), repoName: "repo"), isEmbedded: true
    )
    .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth, height: HfRadius.Metrics.taskDetailNarrowPreviewHeight)
    .preferredColorScheme(.dark)
}

#Preview("Loading, title known - dark") {
    skeletonPreview(TaskLoadingHeader(title: "MT-2477 vibe brief", repoName: "Carousell-iOS")).preferredColorScheme(.dark)
}

#Preview("Loading, title known - light") {
    skeletonPreview(TaskLoadingHeader(title: "MT-2477 vibe brief", repoName: "Carousell-iOS")).preferredColorScheme(.light)
}

#Preview("Loading, nothing known - dark") { skeletonPreview(nil).preferredColorScheme(.dark) }
#Preview("Loading, nothing known - light") { skeletonPreview(nil).preferredColorScheme(.light) }

#Preview("Loading, reduce motion - dark") {
    skeletonPreview(nil).environment(\.shimmerReduceMotionOverride, true).preferredColorScheme(.dark)
}

#Preview("Loading, reduce motion - light") {
    skeletonPreview(nil).environment(\.shimmerReduceMotionOverride, true).preferredColorScheme(.light)
}
#endif
