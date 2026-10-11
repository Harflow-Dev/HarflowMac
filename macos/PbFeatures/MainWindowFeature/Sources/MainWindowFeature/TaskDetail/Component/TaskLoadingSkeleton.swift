//
//  TaskLoadingSkeleton.swift
//  MainWindowFeature
//
//  The task screen while its data is still arriving (the design's "Task loading — shimmer"
//  artboards). It mirrors the loaded layout block for block — content header, the toolbar's four
//  native items and their glass grouping, tab switcher, the 760 pt reading column, the composer —
//  so nothing jumps when the content replaces it.
//

import PbUI
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
        VStack(spacing: PbRadius.Metrics.zero) {
            title
                .padding(.horizontal, isEmbedded ? PbRadius.Metrics.spacing16 : PbRadius.Metrics.spacing24)
                .padding(.top, PbRadius.Metrics.spacing12)
            SlidingSegmentedControl(options: TaskTab.allCases.map { ($0, $0.rawValue) }, selection: .constant(.activity))
                .disabled(true)
                .opacity(0.6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, isEmbedded ? PbRadius.Metrics.spacing16 : PbRadius.Metrics.spacing24)
                .padding(.top, isEmbedded ? PbRadius.Metrics.spacing8 : PbRadius.Metrics.spacing16)
                .padding(.bottom, isEmbedded ? PbRadius.Metrics.spacing8 : PbRadius.Metrics.spacing16)
            ScrollView {
                feed
                    .padding(.horizontal, PbRadius.Metrics.spacing24)
                    .padding(.top, PbRadius.Metrics.spacing12)
                    .readingColumn()
                    // The document probe (§6.2): inside the skeleton feed's own document.
                    .background(ScrollChrome())
            }
            .frame(minHeight: PbRadius.Metrics.zero, maxHeight: .infinity, alignment: .top)
            composer
                .padding(.horizontal, PbRadius.Metrics.spacing24)
                .padding(.bottom, PbRadius.Metrics.spacing20)
                .readingColumn()
        }
        .background(Color.windowBG)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading task")
        .modifier(LoadingToolbar(isEmbedded: isEmbedded))
    }

    @ViewBuilder
    private var title: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            if let header {
                Text(header.title)
                    .font(.pb(.title, weight: .semibold))
                    .foregroundStyle(Color.primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(header.title)
                Text(header.repoName).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).lineLimit(1)
            } else {
                SkeletonBlock(width: PbRadius.Metrics.taskSkeletonHeadingWidth, height: PbRadius.Metrics.taskSkeletonHeadingHeight)
                SkeletonBlock(width: PbRadius.Metrics.taskSkeletonShortLineWidth, height: PbRadius.Metrics.spacing12)
            }
        }
        .frame(minWidth: PbRadius.Metrics.zero, maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    // MARK: Feed

    private var feed: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.taskSkeletonFeedSpacing) {
            promptBubble
            HStack(spacing: PbRadius.Metrics.spacing8) {
                SkeletonBlock(width: PbRadius.Metrics.spacing8, height: PbRadius.Metrics.spacing8, cornerRadius: PbRadius.Metrics.spacing4)
                SkeletonBlock(width: PbRadius.Metrics.taskSkeletonStartWidth, height: PbRadius.Metrics.taskSkeletonCaptionHeight)
            }
            collapsedCard(titleWidth: PbRadius.Metrics.taskSkeletonTitleWidth)
            VStack(alignment: .leading, spacing: PbRadius.Metrics.taskSkeletonLineSpacing) {
                fractionBar(0.96, height: PbRadius.Metrics.taskSkeletonBodyHeight)
                fractionBar(0.70, height: PbRadius.Metrics.taskSkeletonBodyHeight)
            }
            .padding(.vertical, PbRadius.Metrics.spacing2)
            expandedCard
            collapsedCard(titleWidth: PbRadius.Metrics.taskSkeletonLongTitleWidth).opacity(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptBubble: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            fractionBar(1, height: PbRadius.Metrics.spacing12)
            fractionBar(0.88, height: PbRadius.Metrics.spacing12)
            fractionBar(0.52, height: PbRadius.Metrics.spacing12)
        }
        .padding(PbRadius.Metrics.spacing14)
        .frame(width: PbRadius.Metrics.taskSkeletonPromptWidth)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: PbRadius.Metrics.promptBubbleCornerRadius,
                bottomLeadingRadius: PbRadius.Metrics.promptBubbleCornerRadius,
                bottomTrailingRadius: PbRadius.Metrics.promptBubbleTailCornerRadius,
                topTrailingRadius: PbRadius.Metrics.promptBubbleCornerRadius
            )
            .fill(Color.promptBubble)
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func collapsedCard(titleWidth: CGFloat) -> some View {
        ActivityCard {
            HStack(spacing: PbRadius.Metrics.spacing10) {
                SkeletonBlock(width: PbRadius.Metrics.spacing16, height: PbRadius.Metrics.spacing16, cornerRadius: PbRadius.Metrics.spacing4)
                SkeletonBlock(width: titleWidth, height: PbRadius.Metrics.spacing12)
                Spacer(minLength: PbRadius.Metrics.zero)
                SkeletonBlock(width: PbRadius.Metrics.taskSkeletonResultWidth, height: PbRadius.Metrics.spacing10)
            }
        }
    }

    private var expandedCard: some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing12) {
                HStack(spacing: PbRadius.Metrics.spacing10) {
                    SkeletonBlock(width: PbRadius.Metrics.spacing16, height: PbRadius.Metrics.spacing16, cornerRadius: PbRadius.Metrics.spacing4)
                    SkeletonBlock(width: PbRadius.Metrics.taskSkeletonExpandedTitleWidth, height: PbRadius.Metrics.spacing12)
                    Spacer(minLength: PbRadius.Metrics.zero)
                    SkeletonBlock(width: PbRadius.Metrics.taskSkeletonShortLineWidth, height: PbRadius.Metrics.spacing10)
                }
                HStack(spacing: PbRadius.Metrics.spacing6) {
                    ForEach(PbRadius.Metrics.taskSkeletonPillWidths, id: \.self) { SkeletonBlock(width: $0, height: PbRadius.Metrics.taskSkeletonPillHeight) }
                }
                .padding(.leading, PbRadius.Metrics.taskSkeletonDetailInset)
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
        HStack(spacing: PbRadius.Metrics.spacing10) {
            SkeletonBlock(width: PbRadius.Metrics.taskSkeletonComposerWidth, height: PbRadius.Metrics.spacing12)
            Spacer(minLength: PbRadius.Metrics.zero)
            SkeletonBlock(
                width: PbRadius.Metrics.composerSendButtonSize,
                height: PbRadius.Metrics.composerSendButtonSize,
                cornerRadius: PbRadius.Metrics.composerSendButtonSize / 2
            )
        }
        .padding(.leading, PbRadius.Metrics.spacing16)
        .padding(.trailing, PbRadius.Metrics.spacing16)
        .padding(.vertical, PbRadius.Metrics.spacing12)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PbRadius.Metrics.composerCornerRadius))
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
            VStack(spacing: PbRadius.Metrics.zero) {
                HStack {
                    Spacer(minLength: PbRadius.Metrics.zero)
                    actions
                }
                .padding(.horizontal, PbRadius.Metrics.spacing16)
                .padding(.vertical, PbRadius.Metrics.spacing10)
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
        SkeletonBlock(width: PbRadius.Metrics.taskSkeletonStatusWidth, height: PbRadius.Metrics.spacing14,
                      cornerRadius: PbRadius.Metrics.taskSkeletonToolbarBlockRadius)
            .accessibilityHidden(true)
    }

    private var takeoverBlock: some View {
        SkeletonBlock(width: PbRadius.Metrics.taskSkeletonActionWidth, height: PbRadius.Metrics.spacing28,
                      cornerRadius: PbRadius.Metrics.taskSkeletonToolbarBlockRadius)
            .accessibilityHidden(true)
    }

    private var moreBlock: some View {
        SkeletonBlock(width: PbRadius.Metrics.taskSkeletonToolbarButtonWidth, height: PbRadius.Metrics.spacing28,
                      cornerRadius: PbRadius.Metrics.taskSkeletonToolbarBlockRadius)
            .accessibilityHidden(true)
    }

    private var inspectorBlock: some View {
        SkeletonBlock(width: PbRadius.Metrics.taskSkeletonToolbarButtonWidth, height: PbRadius.Metrics.spacing28,
                      cornerRadius: PbRadius.Metrics.taskSkeletonToolbarBlockRadius)
            .accessibilityHidden(true)
    }

    private var actions: some View {
        HStack(spacing: PbRadius.Metrics.spacing8) {
            SkeletonBlock(width: PbRadius.Metrics.taskSkeletonStatusWidth, height: PbRadius.Metrics.spacing14,
                          cornerRadius: PbRadius.Metrics.taskSkeletonToolbarBlockRadius)
            SkeletonBlock(width: PbRadius.Metrics.taskSkeletonActionWidth, height: PbRadius.Metrics.spacing28,
                          cornerRadius: PbRadius.Metrics.taskSkeletonToolbarBlockRadius)
            SkeletonBlock(width: PbRadius.Metrics.taskSkeletonToolbarButtonWidth, height: PbRadius.Metrics.spacing28,
                          cornerRadius: PbRadius.Metrics.taskSkeletonToolbarBlockRadius)
            SkeletonBlock(width: PbRadius.Metrics.taskSkeletonToolbarButtonWidth, height: PbRadius.Metrics.spacing28,
                          cornerRadius: PbRadius.Metrics.taskSkeletonToolbarBlockRadius)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
@MainActor
private func skeletonPreview(_ header: TaskLoadingHeader?) -> some View {
    NavigationStack { TaskLoadingSkeleton(header: header) }
        .frame(width: PbRadius.Metrics.taskDetailPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
}

#Preview("Loading, long title - narrow") {
    NavigationStack {
        TaskLoadingSkeleton(header: TaskLoadingHeader(
            title: "Investigate the intermittent authentication failure and repair the session refresh flow across all application entry points",
            repoName: "repo"
        ))
    }
    .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
}

#Preview("Loading, unbroken title - embedded") {
    TaskLoadingSkeleton(
        header: TaskLoadingHeader(title: String(repeating: "LongUnbrokenTaskIdentifier", count: 8), repoName: "repo"),
        isEmbedded: true
    )
    .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
    .preferredColorScheme(.light)
}

#Preview("Loading, unbroken title - embedded dark") {
    TaskLoadingSkeleton(
        header: TaskLoadingHeader(title: String(repeating: "LongUnbrokenTaskIdentifier", count: 8), repoName: "repo"), isEmbedded: true
    )
    .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
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
