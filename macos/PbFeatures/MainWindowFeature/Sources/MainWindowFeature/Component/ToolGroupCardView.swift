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

struct ToolGroupCardView: View {
    let group: ToolGroup
    let start: Date?
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        ActivityCard {
            VStack(alignment: .leading, spacing: 12) {
                Button(action: onToggle) { header }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint(isExpanded ? "Hides the individual calls" : "Shows the individual calls")
                if isExpanded {
                    if !group.pillNames.isEmpty {
                        FilePillsView(names: group.pillNames, overflowCount: group.overflowCount)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(group.members) { member in
                            ToolRow(model: ToolRowModel(call: member.call, result: member.result, live: member.live))
                        }
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: group.bucket.iconName)
                .frame(width: 16)
                .foregroundStyle(Color.secondaryText)
            VStack(alignment: .leading, spacing: 2) {
                Text(group.summary).font(.pb(.body, weight: .medium))
                if let subtitle = group.subtitle {
                    Text(subtitle).font(.pb(.caption)).foregroundStyle(Color.secondaryText).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if group.isRunning { ProgressView().controlSize(.mini) }
            Text(group.timeRangeText(start: start))
                .font(.pb(.caption))
                .monospacedDigit()
                .foregroundStyle(Color.secondaryText)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.pb(.caption, weight: .semibold))
                .foregroundStyle(Color.secondaryText)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - FilePillsView

/// File names as wrapping pills, with a trailing "+N more" when the card holds more.
struct FilePillsView: View {
    let names: [String]
    let overflowCount: Int

    var body: some View {
        PillFlowLayout(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.offset) { _, name in pill(name) }
            if overflowCount > 0 { pill("+\(overflowCount) more") }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(.pb(.caption))
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.pillFill))
    }
}

// MARK: - PillFlowLayout

/// Places subviews left to right and wraps to a new line when the next one does not fit.
struct PillFlowLayout: Layout {
    var spacing: CGFloat = 6

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
        VStack(spacing: 12) {
            ToolGroupCardView(group: Self.readGroup, start: .now, isExpanded: false, onToggle: {})
            ToolGroupCardView(group: Self.readGroup, start: .now, isExpanded: true, onToggle: {})
            ToolGroupCardView(group: Self.runningGroup, start: .now, isExpanded: false, onToggle: {})
        }
        .padding()
        .frame(width: 560)
        .background(Color.windowBG)
    }
}

#Preview("Tool group card - light") { ToolGroupCardPreview().preferredColorScheme(.light) }
#Preview("Tool group card - dark") { ToolGroupCardPreview().preferredColorScheme(.dark) }
#endif
