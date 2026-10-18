//
//  ToolGroupCardView.swift
//  MainWindowFeature
//
//  A card folding adjacent tool calls: icon, summary, time range and a chevron. Expanded, a read
//  card first shows its file names as pills, then every call as an ordinary `ToolRow`. Expansion
//  state belongs to the feed (keyed by the group id), not to this view.
//

import PbUI
import SwiftUI

// MARK: - ToolGroupCardView

/// A card folding adjacent tool calls: icon, summary, time range and a chevron. Redesign §5.4: the
/// grouped-card treatment (`GroupedActivityCard` + `ActivityCardRow`'s 10 × 14 rows with hairline
/// dividers between them), a 15 pt row icon, and the strong-verb summary with monospaced detail.
/// Expanded, a read card first shows its file names as pills, then every call as an ordinary
/// `ToolRow` in its own row — each call stays its own row; adjacent groups are never merged, and
/// expansion state belongs to the feed (keyed by the group id), not to this view.
struct ToolGroupCardView: View {
    let group: ToolGroup
    let start: Date?
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var seenMemberIDs: Set<String> = []

    var body: some View {
        GroupedActivityCard {
            headerButton
            if isExpanded { expandedContent }
        }
    }

    private var headerButton: some View {
        Button(action: onToggle) {
            ActivityCardRow { header }
                .textSelection(.disabled)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Hides the individual calls" : "Shows the individual calls")
    }

    @ViewBuilder
    private var expandedContent: some View {
        if !group.pillNames.isEmpty {
            ActivityCardDivider()
            ActivityCardRow {
                FilePillsView(names: group.pillNames, paths: group.pillPaths, overflowCount: group.overflowCount)
            }
        }
        ForEach(group.members) { member in
            ActivityCardDivider()
            ActivityCardRow {
                ToolRow(model: ToolRowModel(call: member.call, result: member.result, live: member.live))
            }
            .pbFadeIn(animate: !seenMemberIDs.contains(member.id))
            .onAppear { seenMemberIDs.insert(member.id) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: PbRadius.Metrics.spacing8) {
            Image(systemName: group.bucket.iconName)
                .font(.pb(.headline))
                .frame(width: PbRadius.Metrics.activityIconSize)
                .foregroundStyle(Color.secondaryText)
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                Text(group.summary).font(.pb(.body, weight: .bold)).monospacedDigit()
                if let subtitle = group.subtitle {
                    Text(subtitle).font(.pb(.caption)).monospacedDigit().foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: PbRadius.Metrics.spacing8)
            if group.isRunning { RunningSpinner(size: PbRadius.Metrics.spacing12) }
            Text(group.timeRangeText(start: start))
                .font(.pb(.caption))
                .monospacedDigit()
                .foregroundStyle(Color.tertiaryText)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.pb(.caption, weight: .semibold))
                .foregroundStyle(Color.tertiaryText)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - FilePillsView

/// File names as wrapping pills, with a trailing "+N more" when the card holds more.
struct FilePillsView: View {
    let names: [String]
    /// The full path behind each name; tapping a pill opens it in its default app.
    var paths: [String] = []
    let overflowCount: Int
    @Environment(\.openURL) private var openURL

    var body: some View {
        PillFlowLayout(spacing: PbRadius.Metrics.spacing6) {
            ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                if index < paths.count, let link = FileLinks.link(forPath: paths[index]) {
                    Button { openURL(link) } label: { pill(name) }
                        .buttonStyle(.plain)
                        .help("Open \(paths[index])")
                        .accessibilityLabel("Open \(name)")
                } else {
                    pill(name)
                }
            }
            if overflowCount > 0 { pill("+\(overflowCount) more").monospacedDigit() }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.pb(.secondary, design: .monospaced))
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, PbRadius.Metrics.spacing8)
            .padding(.vertical, PbRadius.Metrics.rowLineSpacing)
            .background(Capsule().fill(Color.pillFill))
    }
}

// MARK: - PillFlowLayout

/// Places subviews left to right and wraps to a new line when the next one does not fit.
struct PillFlowLayout: Layout {
    var spacing: CGFloat = PbRadius.Metrics.spacing6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? result.usedWidth, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], usedWidth: CGFloat, height: CGFloat) {
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            // Capped at the line width so a long file name truncates instead of overflowing the column.
            let natural = subview.sizeThatFits(.unspecified)
            let size = natural.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : natural
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            usedWidth = max(usedWidth, x - spacing)
        }
        return (frames, usedWidth, y + lineHeight)
    }
}

#if DEBUG
private struct ToolGroupCardPreview: View {
    private static func member(_ seq: Int, name: String, pending: Bool = false) -> ToolGroupMember {
        let item = PreviewFixtures.toolItem(
            tool: "Read", category: "read", command: nil, path: "/Users/example/repo/Sources/\(name)",
            pending: pending, seq: seq * 2, callID: "c\(seq)"
        )
        guard case .tool(let call, let result) = item.body else { fatalError("expected a tool item") }
        return ToolGroupMember(id: "t#\(seq)", call: call, result: result, timestamp: .now.addingTimeInterval(Double(seq) * 20), live: true)
    }

    private static let names = (1 ... 12).map { "File\($0).swift" }
    private static let readGroup = ToolGroup(
        id: "t#1", taskID: "t", bucket: .read, members: names.enumerated().map { member($0.offset + 1, name: $0.element) }
    )
    private static let runningGroup = ToolGroup(
        id: "t#20", taskID: "t", bucket: .read, members: [member(20, name: "AppDelegate.swift", pending: true)]
    )

    var body: some View {
        VStack(spacing: PbRadius.Metrics.spacing12) {
            ToolGroupCardView(group: Self.readGroup, start: .now, isExpanded: false, onToggle: {})
            ToolGroupCardView(group: Self.readGroup, start: .now, isExpanded: true, onToggle: {})
            ToolGroupCardView(group: Self.runningGroup, start: .now, isExpanded: false, onToggle: {})
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(width: PbRadius.Metrics.taskComponentPreviewWidth)
        .background(Color.windowBG)
    }
}

#Preview("Tool group card - light") { ToolGroupCardPreview().preferredColorScheme(.light) }
#Preview("Tool group card - dark") { ToolGroupCardPreview().preferredColorScheme(.dark) }

#Preview("File pills, long name and overflow - light") {
    FilePillsView(names: ["AppDelegate.swift", String(repeating: "LongName", count: 12)], paths: ["/repo/AppDelegate.swift"], overflowCount: 3)
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
.preferredColorScheme(.light)
}

#Preview("File pills, long name and overflow - dark") {
    FilePillsView(names: ["AppDelegate.swift", String(repeating: "LongName", count: 12)], paths: ["/repo/AppDelegate.swift"], overflowCount: 3)
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
.preferredColorScheme(.dark)
}
#endif
