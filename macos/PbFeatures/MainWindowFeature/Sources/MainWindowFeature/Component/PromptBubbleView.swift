//
//  PromptBubbleView.swift
//  MainWindowFeature
//
//  A right-aligned tinted bubble for a prompt or a message the user sent. Long text is clamped to
//  three lines with an inline "Show more" that expands in place — it never jumps to the Prompt tab.
//

import PbUI
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
    @State private var isExpanded: Bool

    init(text: String, caption: String? = nil, isInitiallyExpanded: Bool = false) {
        self.text = text
        self.caption = caption
        _isExpanded = State(initialValue: isInitiallyExpanded)
    }

    /// Whether the text is long enough to be clamped behind "Show more".
    nonisolated static func isLong(_ text: String) -> Bool {
        text.count > collapsedCharacterLimit || text.reduce(0) { $1.isNewline ? $0 + 1 : $0 } >= collapsedLineLimit
    }

    var body: some View {
        let isLong = Self.isLong(text)
        HStack(spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: 4) {
                if let caption {
                    Text(caption).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                }
                Text(text)
                    .font(.pb(.reading))
                    .lineSpacing(3)
                    .lineLimit(isLong && !isExpanded ? Self.collapsedLineLimit : nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLong {
                    Button(isExpanded ? "Show less" : "Show more") { isExpanded.toggle() }
                        .buttonStyle(.link)
                        .font(.pb(.secondary))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(Color.promptBubble))
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

#if DEBUG
private struct PromptBubblePreview: View {
    var body: some View {
        VStack(alignment: .trailing, spacing: 12) {
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
        .padding()
        .frame(width: 480)
        .background(Color.windowBG)
    }
}

#Preview("Prompt bubble - light") { PromptBubblePreview().preferredColorScheme(.light) }
#Preview("Prompt bubble - dark") { PromptBubblePreview().preferredColorScheme(.dark) }
#endif
