//
//  DetailLine.swift
//  HfUI
//

import SwiftUI

// MARK: - DetailLine

/// One detail line: a caption label above a monospaced, selectable value, as the design's `codeRow` draws
/// the refusal "Code" under a message. Shared by the runtime gates, the Harnesses states and the other
/// surfaces that print a refusal code beside its sentence.
public struct DetailLine: View {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
            Text(label)
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
            Text(value)
                .font(.hf(.secondary, design: .monospaced))
                .foregroundStyle(Color.primaryText)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("DetailLine - light") {
    DetailLine(label: "Code", value: "setup_error")
        .padding()
        .preferredColorScheme(.light)
}

#Preview("DetailLine - dark") {
    DetailLine(label: "Code", value: "incompatible_runtime")
        .padding()
        .preferredColorScheme(.dark)
}
#endif
