//
//  RawEventsSheetView.swift
//  MainWindowFeature
//
//  Raw events no longer have a tab (settled plan D18): the "…" menu opens this sheet, which wraps
//  the existing `RawEventsPaneView` with a title and a Done button.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - RawEventsSheetView

struct RawEventsSheetView: View {
    let events: [TaskEvent]
    let path: String
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Raw events").font(.pb(.headline, weight: .semibold))
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction)
            }
            .padding(14)
            Divider()
            RawEventsPaneView(events: events, path: path)
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(Color.windowBG)
    }
}

#if DEBUG
#Preview("Light") {
    RawEventsSheetView(events: [], path: "/tmp/example.events.jsonl") {}
        .preferredColorScheme(.light)
}

#Preview("Dark") {
    RawEventsSheetView(events: [], path: "/tmp/example.events.jsonl") {}
        .preferredColorScheme(.dark)
}
#endif
