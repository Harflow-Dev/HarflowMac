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

    let text: String
    var prepared: StreamingMarkdownState?
    @State private var staticPresentation = StreamingMarkdownState()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach((prepared ?? staticPresentation).blocks) { block in
                blockView(block.content)
            }
        }
        .font(.hf(.reading))
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

    private func styled(_ value: AttributedString) -> AttributedString {
        var result = value
        for run in value.runs where run.inlinePresentationIntent?.contains(.code) == true {
            result[run.range].font = Self.codeFont
            result[run.range].backgroundColor = .codeFill
        }
        return result
    }

    @ViewBuilder
    private func blockView(_ content: StreamingMarkdownBlock.Content) -> some View {
        switch content {
        case .heading(let value):
            Text(styled(value)).font(.hf(.headline, weight: .semibold))
        case .bullet(let value):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(styled(value)).lineSpacing(6)
            }
        case .code(let value):
            Text(value)
                .font(.hf(.secondary, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: HfRadius.button).fill(Color.codeFill))
        case .paragraph(let value):
            Text(styled(value)).lineSpacing(6)
        case .table(let rows):
            table(rows).padding(.vertical, 4)
        case .numbered(let marker, let value):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit()
                Text(styled(value)).lineSpacing(6)
            }
        case .quote(let value):
            MarkdownText.quote(Text(styled(value)).lineSpacing(6))
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
