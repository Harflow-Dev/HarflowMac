//
//  ParallelLoadingSkeleton.swift
//  MainWindowFeature
//
//  The loading state of a Parallel group (HarflowDesign 4ff7d83 `loading-two`; 2934681 `parallel-group/loading`): real
//  lane frames (head, body, foot, 1 pt separators) holding placeholder blocks and a real, disabled composer, so the
//  lanes do not move when the group's membership resolves. One accessibility element describes the whole thing.
//

import HfUI
import SwiftUI

// MARK: - ParallelLoadingSkeleton

/// The lane row while a group's membership is unknown. `laneCount` is the number of lanes to draw (the columns known so
/// far, else two).
struct ParallelLoadingSkeleton: View {
    /// The lanes drawn when nothing says how many there will be.
    static let defaultLaneCount = 2
    let laneCount: Int

    private typealias Metrics = TaskScreenStyle.Lane

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                // The same lane frames as the loaded row, so a resolved group does not move.
                HStack(alignment: .top, spacing: HfRadius.Metrics.zero) {
                    ForEach(0 ..< max(1, laneCount), id: \.self) { index in
                        lane(index: index)
                            .frame(width: ParallelLayout.columnWidth(memberCount: max(1, laneCount), availableWidth: proxy.size.width),
                                   height: max(0, proxy.size.height))
                        ParallelLaneSeparator(chrome: .lane)
                    }
                }
                .background(ScrollChrome())
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading Parallel group")
    }

    // MARK: Lane

    private func lane(index: Int) -> some View {
        ParallelLaneSurface {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.zero) {
                head
                    .padding(.horizontal, HfRadius.Metrics.spacing16)
                    .padding(.vertical, HfRadius.Metrics.spacing12)
                ParallelLaneSurfaceHairline()
                body(index: index)
                    .padding(Metrics.paddingHorizontal)
                    .frame(maxHeight: .infinity, alignment: .top)
                ParallelLaneSurfaceHairline()
                MessageBoxView(model: MessageBoxModel(
                    canSend: false, canContinue: false, isBusy: false, label: "Message", hint: "", placeholder: "",
                    buttonLabel: "Send", fieldAccessibilityLabel: "Message", sendAccessibilityLabel: "Send"
                ), style: .lane) { _ in false }
                    .disabled(true)
                    .padding(HfRadius.Metrics.spacing12)
            }
        }
    }

    /// A 16 circle, 120 and 80 wide lines, a 64 pill and a 26 square: the head's glyph, title, caption, status and menu.
    private var head: some View {
        HStack(alignment: .center, spacing: Metrics.headGap) {
            SkeletonBlock(width: 16, height: 16, cornerRadius: 8)
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                SkeletonBlock(width: 120, height: 12)
                SkeletonBlock(width: 80, height: 10)
            }
            Spacer(minLength: HfRadius.Metrics.zero)
            SkeletonBlock(width: 64, height: 12)
            SkeletonBlock(width: Metrics.menuSize, height: Metrics.menuSize, cornerRadius: 6)
        }
    }

    /// Alternating long and short bodies, so the lanes do not read as one repeated block.
    private func body(index: Int) -> some View {
        let widths: [CGFloat?] = index.isMultiple(of: 2) ? [nil, 240, nil, 180, 260] : [220, nil, 160]
        return VStack(alignment: .leading, spacing: Metrics.rowGap) {
            ForEach(Array(widths.enumerated()), id: \.offset) { _, width in
                SkeletonBlock(width: width, height: 12).frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            }
        }
    }
}

// MARK: - ParallelLaneSurfaceHairline

/// The lane's 1 pt `--border` rule between head, body and foot.
struct ParallelLaneSurfaceHairline: View {
    var body: some View {
        Rectangle().fill(TaskScreenStyle.Colors.border.color).frame(height: ParallelLayout.dividerWidth).accessibilityHidden(true)
    }
}
