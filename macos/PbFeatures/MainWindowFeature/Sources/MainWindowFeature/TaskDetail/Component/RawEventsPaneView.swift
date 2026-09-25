//
//  RawEventsPaneView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TimelineViews.swift` (`RawEventsPane`). A trivial value view — no
//  Model needed, per the screen shape's "trivial components may take plain values" allowance.
//

import MonitorCore
import SwiftUI

struct RawEventsPaneView: View {
    let events: [TaskEvent]
    let path: String
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(events) { event in
                    Text(event.rawLine)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(event.isUnknown ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            Text(path).font(.system(size: 10)).foregroundStyle(.secondary).padding(6).textSelection(.enabled)
        }
    }
}

#if DEBUG
#Preview {
    RawEventsPaneView(events: [], path: "/tmp/example.events.jsonl")
        .frame(width: 400, height: 300)
}
#endif
