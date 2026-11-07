//
//  ReadingMarkdownView.swift
//  MainWindowFeature
//
//  Agent text at reading size with generous line spacing. HfUI's `MarkdownText` fixes its own body
//  font, so this renders the same parsed blocks (`MarkdownText.blocks`/`inline`) at `.reading`.
//

import HfUI
import SwiftUI

// MARK: - ReadingMarkdownView

struct ReadingMarkdownView: View {
    /// One step below the 14 pt reading size: monospaced glyphs read larger than SF at equal size.
    private static let codeFont = Font.hf(.body, design: .monospaced)
    private static let transcriptCodeFont = TaskScreenStyle.mono(size: TaskScreenStyle.InlineCode.fontSize)

    let text: String
    var prepared: StreamingMarkdownState?
    @State private var staticPresentation = StreamingMarkdownState()
    @Environment(\.activityFeedStyle) private var feedStyle

    private var transcript: Bool { feedStyle.isTranscript }
    private var lineSpacing: CGFloat { transcript ? TaskScreenStyle.bodyLineSpacing : 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: transcript ? 0 : 8) {
            let blocks = (prepared ?? staticPresentation).blocks
            if transcript {
                ForEach(Array(blocks.enumerated()), id: \.element.id) { index, block in
                    blockView(block.content)
                        .padding(.top, index == 0 ? 0 : Self.transcriptSpacing(after: blocks[index - 1].content, before: block.content))
                }
            } else {
                ForEach(blocks) { block in
                    blockView(block.content)
                }
            }
        }
        .font(.hf(.reading))
        .modifier(TranscriptProseColor(isOn: transcript))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        .task(id: prepared == nil ? text : "") {
            guard prepared == nil else { return }
            let value = text
            let result = await Task.detached(priority: .userInitiated) {
                StreamingMarkdownState().updating(text: value, isStreaming: false)
            }.value
            guard !Task.isCancelled else { return }
            staticPresentation = result
        }
    }

    /// `.hd-msg-agent`: 10 pt between paragraphs and after a list, none between the items of one list.
    private static func transcriptSpacing(after previous: StreamingMarkdownBlock.Content, before next: StreamingMarkdownBlock.Content) -> CGFloat {
        isListItem(previous) && isListItem(next) ? 0 : TaskScreenStyle.AgentProse.paragraphSpacing
    }

    private static func isListItem(_ content: StreamingMarkdownBlock.Content) -> Bool {
        switch content {
        case .bullet, .numbered: true
        default: false
        }
    }

    private func styled(_ value: AttributedString) -> AttributedString {
        var result = value
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            if transcript {
                result[run.range].font = Self.transcriptCodeFont
                result[run.range].backgroundColor = TaskScreenStyle.InlineCode.fill.color
            } else {
                result[run.range].font = Self.codeFont
                result[run.range].backgroundColor = .codeFill
            }
        }
        return result
    }

    @ViewBuilder
    private func blockView(_ content: StreamingMarkdownBlock.Content) -> some View {
        switch content {
        case .heading(let value):
            Text(styled(value)).font(.hf(.headline, weight: .semibold))
        case .bullet(let value):
            HStack(alignment: .firstTextBaseline, spacing: transcript ? 0 : 6) {
                if transcript {
                    Text("•").frame(width: TaskScreenStyle.AgentProse.listIndent, alignment: .leading)
                } else {
                    Text("•")
                }
                Text(styled(value)).lineSpacing(lineSpacing)
            }
        case .code(let value):
            Text(value)
                .font(.hf(.secondary, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: HfRadius.button).fill(feedStyle.codeFill))
        case .paragraph(let value):
            Text(styled(value)).lineSpacing(lineSpacing)
        case .table(let rows):
            table(rows).padding(.vertical, 4)
        case .numbered(let marker, let value):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
.monospacedDigit()
                    .frame(minWidth: transcript ? TaskScreenStyle.AgentProse.listIndent - 6 : nil, alignment: .trailing)
                Text(styled(value)).lineSpacing(lineSpacing)
            }
        case .quote(let value):
            MarkdownText.quote(Text(styled(value)).lineSpacing(lineSpacing))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func table(_ rows: [[AttributedString]]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    ForEach(rows[index].indices, id: \.self) { column in
                        Text(styled(rows[index][column]))
                            .fontWeight(index == 0 ? .semibold : nil)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index < rows.count - 1 { Divider() }
            }
        }
    }
}

// MARK: - TranscriptProseColor

/// `.hd-msg-agent`'s `--text` colour in the transcript style; every other style inherits the foreground.
struct TranscriptProseText: ViewModifier {
    let isOn: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isOn { content.foregroundStyle(TaskScreenStyle.AgentProse.color.color) } else { content }
    }
}

private struct TranscriptProseColor: ViewModifier {
    let isOn: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if isOn { content.foregroundStyle(TaskScreenStyle.AgentProse.color.color) } else { content }
    }
}

#if DEBUG
private struct ReadingMarkdownPreview: View {
    static let sample = """
    ## Root cause
    The store is read **before** it is warmed, so a cold keychain returns `nil`.
    - Warm it first
    - Then read
    ```
    let value = warmed ? read(key) : nil
    ```
    | File | Change |
    |---|---|
    | `Keychain.swift` | warm before read |
    | `LoginTests.swift` | regression test |
    ---
    1. Reproduce with a cold keychain
    2. Warm, then read
    > Verified on macOS 26 only.
    """

    var body: some View {
        ReadingMarkdownView(text: Self.sample)
            .padding()
            .frame(width: 480)
            .background(Color.windowBG)
    }
}

#Preview("Reading text - light") { ReadingMarkdownPreview().preferredColorScheme(.light) }
#Preview("Reading text - dark") { ReadingMarkdownPreview().preferredColorScheme(.dark) }
#endif
