//
//  SummaryEntryRow.swift
//  MainWindowFeature
//
//  The standalone transcript's closing entry: the "Summary" divider (`.hd-turn-sep`) and the reported
//  summary as agent prose beneath it.
//

import HfUI
import SwiftUI

// MARK: - SummaryEntryRow

/// The "Summary" divider and the reported summary, drawn with the shared turn-separator divider and the
/// agent message's prose path, a transcript row gap apart. The divider is an accessibility heading.
struct SummaryEntryRow: View {
    let entry: SummaryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: TaskScreenStyle.Transcript.gap) {
            TurnSeparatorDivider(label: "Summary")
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            AgentProseText(text: entry.text, markdown: entry.markdown)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
