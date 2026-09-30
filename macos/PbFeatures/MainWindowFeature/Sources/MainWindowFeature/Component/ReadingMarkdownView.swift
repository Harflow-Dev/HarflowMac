//
//  ReadingMarkdownView.swift
//  MainWindowFeature
//
//  Agent text at reading size with generous line spacing. PbUI's `MarkdownText` fixes its own body
//  font, so this renders the same parsed blocks (`MarkdownText.blocks`/`inline`) at `.reading`.
//

import PbUI
import SwiftUI

// MARK: - ReadingMarkdownView

struct ReadingMarkdownView: View {
    /// One step below the 14 pt reading size: monospaced glyphs read larger than SF at equal size.
    private static let codeFont = Font.pb(.body, design: .monospaced)

    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownText.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let value):
                    Text(MarkdownText.inline(value, codeFont: Self.codeFont)).font(.pb(.headline, weight: .semibold))
                case .bullet(let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(MarkdownText.inline(value, codeFont: Self.codeFont)).lineSpacing(6)
                    }
                case .code(let value):
                    Text(value)
                        .font(.pb(.secondary, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: PbRadius.button).fill(Color.codeFill))
                case .paragraph(let value):
                    Text(MarkdownText.inline(value, codeFont: Self.codeFont)).lineSpacing(6)
                case .table(let rows):
                    MarkdownText.table(rows, codeFont: Self.codeFont).padding(.vertical, 4)
                case .numbered(let marker, let value):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).monospacedDigit()
                        Text(MarkdownText.inline(value, codeFont: Self.codeFont)).lineSpacing(6)
                    }
                case .quote(let value):
                    MarkdownText.quote(Text(MarkdownText.inline(value, codeFont: Self.codeFont)).lineSpacing(6))
                case .rule:
                    Divider().padding(.vertical, 4)
                }
            }
        }
        .font(.pb(.reading))
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
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
