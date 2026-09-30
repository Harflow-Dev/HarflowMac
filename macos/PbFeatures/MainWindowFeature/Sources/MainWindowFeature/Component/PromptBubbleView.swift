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
    static let collapsedLineLimit = 3

    let text: String
    var caption: String?
    @State private var isExpanded = false
    @State private var isClamped = false

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: 4) {
                if let caption {
                    Text(caption).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                }
                Text(text)
                    .font(.pb(.reading))
                    .lineSpacing(3)
                    .lineLimit(isExpanded ? nil : Self.collapsedLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .background(ClampProbe(text: text, isClamped: $isClamped, isExpanded: isExpanded))
                if isClamped || isExpanded {
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

// MARK: - ClampProbe

/// Reports whether the clamped text is shorter than the same text unclamped, by laying out a hidden
/// copy with no line limit at the same width.
private struct ClampProbe: View {
    let text: String
    @Binding var isClamped: Bool
    let isExpanded: Bool

    var body: some View {
        GeometryReader { visible in
            Text(text)
                .font(.pb(.reading))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: visible.size.width, alignment: .leading)
                .hidden()
                .background(GeometryReader { full in
                    Color.clear.preference(key: FullHeightKey.self, value: full.size.height)
                })
                .onPreferenceChange(FullHeightKey.self) { fullHeight in
                    guard !isExpanded else { return }
                    let clamped = fullHeight > visible.size.height + 1
                    if clamped != isClamped { isClamped = clamped }
                }
        }
    }
}

private struct FullHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
        }
        .padding()
        .frame(width: 480)
        .background(Color.windowBG)
    }
}

#Preview("Prompt bubble - light") { PromptBubblePreview().preferredColorScheme(.light) }
#Preview("Prompt bubble - dark") { PromptBubblePreview().preferredColorScheme(.dark) }
#endif
