//
//  PromptBubbleView.swift
//  MainWindowFeature
//
//  A right-aligned tinted bubble for a prompt or a message the user sent. Long text is clamped to
//  three lines with an inline "Show more" that expands in place — it never navigates away.
//

import HfUI
import SwiftUI

// MARK: - PromptBubbleView

struct PromptBubbleView: View {
    nonisolated static let collapsedLineLimit = 3
    /// Past this many characters (or more than `collapsedLineLimit` lines) the bubble offers
    /// "Show more". Decided from the text alone: an earlier version measured a hidden copy of the
    /// text and fed the result back into state, and on some prompts that layout feedback never
    /// settled — the window grew thousands of points tall and expanding the bubble hung the app.
    nonisolated static let collapsedCharacterLimit = 240

    let text: String
    var caption: String?
    let isPending: Bool
    var note: String?
    var onCancel: (() -> Void)?
    var isCancelDisabled = false
    @State private var localExpanded: Bool
    @Environment(\.activityFeedDisclosure) private var disclosure
    @Environment(\.activityFeedStyle) private var feedStyle
    var disclosureID: String?

    private var isExpanded: Bool {
        get {
            guard let disclosure else { return localExpanded }
            return disclosure.state.expandedPrompts.contains(disclosureID ?? disclosure.rowID)
        }
        nonmutating set {
            guard let disclosure else { localExpanded = newValue; return }
            let key = disclosureID ?? disclosure.rowID
            if newValue {
                disclosure.state.expandedPrompts.insert(key)
            } else {
                disclosure.state.expandedPrompts.remove(key)
            }
        }
    }

    init(text: String, caption: String? = nil, isInitiallyExpanded: Bool = false, isPending: Bool = false, disclosureID: String? = nil,
         note: String? = nil, onCancel: (() -> Void)? = nil, isCancelDisabled: Bool = false) {
        self.text = text
        self.caption = caption
        self.isPending = isPending
        self.disclosureID = disclosureID
        self.note = note
        self.onCancel = onCancel
        self.isCancelDisabled = isCancelDisabled
        _localExpanded = State(initialValue: isInitiallyExpanded)
    }

    /// Whether the text is long enough to be clamped behind "Show more".
    nonisolated static func isLong(_ text: String) -> Bool {
        text.count > collapsedCharacterLimit || text.reduce(0) { $1.isNewline ? $0 + 1 : $0 } >= collapsedLineLimit
    }

    var body: some View {
        let isLong = Self.isLong(text)
        let transcript = feedStyle.isTranscript
        PromptBubbleTrailingLayout(fraction: transcript ? TaskScreenStyle.UserBubble.maxWidthFraction : 0.75,
                                   cap: transcript ? .infinity : 420) {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                if let caption {
                    Text(caption).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                }
                Text(text)
                    .font(.hf(.reading))
                    .foregroundStyle(isPending ? Color.secondaryText : Color.primaryText)
                    .lineSpacing(transcript ? TaskScreenStyle.bodyLineSpacing : HfRadius.Metrics.spacing6)
                    .lineLimit(isLong && !isExpanded ? Self.collapsedLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLong {
                    Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                        .buttonStyle(.link)
                        .font(.hf(.secondary))
                }
                if let note {
                    Text(note)
                        .font(.hf(.secondary))
                        .foregroundStyle(Color.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .buttonStyle(.plain)
                        .font(.hf(.secondary))
                        .disabled(isCancelDisabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .accessibilityLabel("Cancel queued message")
                }
            }
            .padding(.horizontal, transcript ? TaskScreenStyle.UserBubble.paddingHorizontal : HfRadius.Metrics.spacing14)
            .padding(.vertical, transcript ? TaskScreenStyle.UserBubble.paddingVertical : HfRadius.Metrics.spacing10)
            .background(bubbleShape(transcript: transcript))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The standard bubble keeps its tailed corner; the transcript bubble is `.hd-msg-user`: `surface-active`
    /// fill, one radius on every corner.
    @ViewBuilder private func bubbleShape(transcript: Bool) -> some View {
        if transcript {
            RoundedRectangle(cornerRadius: TaskScreenStyle.UserBubble.cornerRadius)
                .fill(TaskScreenStyle.UserBubble.fill.color.opacity(isPending ? 0.45 : 1))
        } else {
            UnevenRoundedRectangle(
                topLeadingRadius: HfRadius.Metrics.promptBubbleCornerRadius,
                bottomLeadingRadius: HfRadius.Metrics.promptBubbleCornerRadius,
                bottomTrailingRadius: HfRadius.Metrics.promptBubbleTailCornerRadius,
                topTrailingRadius: HfRadius.Metrics.promptBubbleCornerRadius
            )
            .fill(isPending ? Color.promptBubble.opacity(0.45) : Color.promptBubble)
        }
    }
}

// MARK: - PromptBubbleTrailingLayout

struct PromptBubbleTrailingLayout: Layout {
    typealias Cache = Void

    /// The bubble's widest share of the offered width, and its absolute cap.
    var fraction: CGFloat = 0.75
    var cap: CGFloat = 420

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        guard let bubble = subviews.first else { return .zero }
        let width = bubbleWidth(for: bubble, proposedWidth: proposal.width)
        let height = bubble.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        let containerWidth = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil } ?? width
        return CGSize(width: containerWidth, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        guard let bubble = subviews.first else { return }
        let width = bubbleWidth(for: bubble, proposedWidth: proposal.width)
        bubble.place(
            at: CGPoint(x: bounds.maxX, y: bounds.minY),
            anchor: .topTrailing,
            proposal: ProposedViewSize(width: width, height: nil)
        )
    }

    private func bubbleWidth(for bubble: LayoutSubview, proposedWidth: CGFloat?) -> CGFloat {
        let naturalWidth = bubble.sizeThatFits(.unspecified).width
        let preferredWidth = naturalWidth.isFinite ? max(0, ceil(naturalWidth)) : 420
        let limit = proposedWidth.flatMap { $0.isFinite ? max(0, $0) * fraction : nil } ?? cap
        return min(preferredWidth, limit, cap)
    }
}

#if DEBUG
private struct PromptBubblePreview: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: HfRadius.Metrics.spacing12) {
            PromptBubbleView(text: "Fix the flaky login test.")
            PromptBubbleView(
                text: "Fix the flaky login test. It fails about one run in five on CI and only when the keychain is cold. "
                    + "Please find the root cause rather than adding a retry, and add a regression test that fails without the fix. "
                    + "Keep the change inside the Login module and do not touch the shared keychain wrapper."
            )
            PromptBubbleView(text: "Also add a test for the edge case", caption: "You · 10:52")
            PromptBubbleView(
                text: String(repeating: "Expanded long prompt text that wraps over several lines. ", count: 8),
                isInitiallyExpanded: true
            )
        }
        .padding(HfRadius.Metrics.spacing16)
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth)
        .background(Color.windowBG)
    }
}

#Preview("Prompt bubble - light") { PromptBubblePreview().preferredColorScheme(.light) }
#Preview("Prompt bubble - dark") { PromptBubblePreview().preferredColorScheme(.dark) }
#Preview("Pending prompt - light") {
    PromptBubbleView(text: "Also cover the cold keychain.", caption: "Pending", isPending: true)
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth)
.preferredColorScheme(.light)
}

#Preview("Pending prompt - dark") {
    PromptBubbleView(text: "Also cover the cold keychain.", caption: "Pending", isPending: true)
        .frame(width: HfRadius.Metrics.taskDetailNarrowPreviewWidth)
.preferredColorScheme(.dark)
}
#endif
