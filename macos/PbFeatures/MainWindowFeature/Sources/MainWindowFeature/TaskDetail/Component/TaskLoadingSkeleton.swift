//
//  TaskLoadingSkeleton.swift
//  MainWindowFeature
//
//  The task screen while its data is still arriving (the design's "Task loading — shimmer"
//  artboards). It mirrors the loaded layout block for block — content header, action toolbar, tab switcher, the 720 pt
//  reading column, the composer — so nothing jumps when the content replaces it.
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
        VStack(spacing: 0) {
            title
                .padding(.horizontal, isEmbedded ? 16 : 24)
                .padding(.top, 12)
            SlidingSegmentedControl(options: TaskTab.allCases.map { ($0, $0.rawValue) }, selection: .constant(.activity))
                .disabled(true)
                .opacity(0.6)
                .padding(.top, isEmbedded ? 8 : 16)
                .padding(.bottom, isEmbedded ? 8 : 16)
            ScrollView {
                feed
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .readingColumn()
            }
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            composer
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
                .readingColumn()
        }
        .background(Color.windowBG)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading task")
        .modifier(LoadingToolbar(isEmbedded: isEmbedded))
    }

    @ViewBuilder
    private var title: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header {
                Text(header.title)
                    .font(.pb(.headline, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(header.title)
                Text(header.repoName).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).lineLimit(1)
            } else {
                SkeletonBlock(width: 220, height: 15)
                SkeletonBlock(width: 90, height: 12)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityHidden(true)
    }

    // MARK: Feed

    private var feed: some View {
        VStack(alignment: .leading, spacing: 18) {
            promptBubble
            HStack(spacing: 8) {
                SkeletonBlock(width: 8, height: 8, cornerRadius: 4)
                SkeletonBlock(width: 260, height: 11)
            }
            collapsedCard(titleWidth: 140)
            VStack(alignment: .leading, spacing: 9) {
                fractionBar(0.96, height: 13)
                fractionBar(0.70, height: 13)
            }
            .padding(.vertical, 2)
            expandedCard
            collapsedCard(titleWidth: 170).opacity(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var promptBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            fractionBar(1, height: 12)
            fractionBar(0.88, height: 12)
            fractionBar(0.52, height: 12)
        }
        .padding(14)
        .frame(width: 460)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4, topTrailingRadius: 14)
                .fill(Color.promptBubble)
        )
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func collapsedCard(titleWidth: CGFloat) -> some View {
        ActivityCard {
            HStack(spacing: 10) {
                SkeletonBlock(width: 16, height: 16, cornerRadius: 4)
                SkeletonBlock(width: titleWidth, height: 12)
                Spacer(minLength: 0)
                SkeletonBlock(width: 72, height: 10)
            }
        }
    }

    private var expandedCard: some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    SkeletonBlock(width: 16, height: 16, cornerRadius: 4)
                    SkeletonBlock(width: 120, height: 12)
                    Spacer(minLength: 0)
                    SkeletonBlock(width: 90, height: 10)
                }
                HStack(spacing: 6) {
                    ForEach([96, 140, 118, 80] as [CGFloat], id: \.self) { SkeletonBlock(width: $0, height: 22) }
                }
                .padding(.leading, 26)
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

    private var composer: some View {
        HStack(spacing: 10) {
            SkeletonBlock(width: 240, height: 12)
            Spacer(minLength: 0)
            SkeletonBlock(width: 30, height: 30, cornerRadius: 8)
        }
        .padding(.leading, 16)
        .padding(.trailing, 12)
        .frame(height: 54)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.composerFill))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.cardBorder, lineWidth: 1))
    }
}

// MARK: - LoadingToolbar

/// Shimmer blocks where the status, primary button and the two icon buttons will be.
/// Embedded details keep these inside their own pane instead of changing the window toolbar.
private struct LoadingToolbar: ViewModifier {
    let isEmbedded: Bool

    func body(content: Content) -> some View {
        if isEmbedded {
            VStack(spacing: 0) {
                HStack {
                    Spacer(minLength: 0)
                    actions
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                content
            }
        } else if #available(macOS 26.0, *) {
            content.toolbar {
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) { actions }.sharedBackgroundVisibility(.hidden)
            }
        } else {
            content.toolbar {
                ToolbarItem(placement: .primaryAction) { actions }
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            SkeletonBlock(width: 110, height: 14, cornerRadius: 7)
            SkeletonBlock(width: 84, height: 28, cornerRadius: 7)
            SkeletonBlock(width: 30, height: 28, cornerRadius: 7)
            SkeletonBlock(width: 30, height: 28, cornerRadius: 7)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
private func skeletonPreview(_ header: TaskLoadingHeader?) -> some View {
    NavigationStack { TaskLoadingSkeleton(header: header) }.frame(width: 1000, height: 700)
}

#Preview("Loading, long title - narrow") {
    NavigationStack {
        TaskLoadingSkeleton(header: TaskLoadingHeader(
            title: "Investigate the intermittent authentication failure and repair the session refresh flow across all application entry points",
            repoName: "repo"
        ))
    }
    .frame(width: 480, height: 700)
}

#Preview("Loading, unbroken title - embedded") {
    TaskLoadingSkeleton(
        header: TaskLoadingHeader(title: String(repeating: "LongUnbrokenTaskIdentifier", count: 8), repoName: "repo"),
        isEmbedded: true
    )
    .frame(width: 480, height: 700)
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
