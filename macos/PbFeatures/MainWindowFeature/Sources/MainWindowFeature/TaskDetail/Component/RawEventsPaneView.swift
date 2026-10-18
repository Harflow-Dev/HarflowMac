//
//  RawEventsPaneView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TimelineViews.swift` (`RawEventsPane`). A trivial value view — no
//  Model needed, per the screen shape's "trivial components may take plain values" allowance.
//

import MonitorCore
import PbUI
import SwiftUI

struct RawEventsPaneView: View {
    let events: [TaskEvent]
    let path: String
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(events) { event in
                    Text(event.rawLine)
                        .font(.pb(.caption, design: .monospaced))
                        .foregroundStyle(event.isUnknown ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
            // The document probe (§6.2): inside the raw events pane's own document.
            .background(ScrollChrome())
        }
        .overlay(alignment: .topTrailing) {
            Text(path).font(.pb(.caption)).foregroundStyle(.secondary).padding(6).textSelection(.enabled)
        }
    }
}

#if DEBUG
#Preview {
    RawEventsPaneView(events: [], path: "/tmp/example.events.jsonl")
        .frame(width: 400, height: 300)
}

/// Dummy overflowing events — the pane's native overlay chrome only shows itself while scrolling.
private func rawEventsPreviewEvents() -> [TaskEvent] {
    (1 ... 30).compactMap { index in
        TaskEvent(line: "{\"v\":1,\"seq\":\(index),\"kind\":\"assistant_text\","
            + "\"text\":\"Raw event line \(index) — dummy preview data that overflows the pane.\"}")
    }
}

#Preview("Raw events - light") {
    RawEventsPaneView(events: rawEventsPreviewEvents(), path: "/tmp/example.events.jsonl")
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Raw events - dark") {
    RawEventsPaneView(events: rawEventsPreviewEvents(), path: "/tmp/example.events.jsonl")
        .frame(width: PbRadius.Metrics.sidebarPreviewWidth, height: PbRadius.Metrics.sidebarPreviewHeight)
        .preferredColorScheme(.dark)
}
#endif
