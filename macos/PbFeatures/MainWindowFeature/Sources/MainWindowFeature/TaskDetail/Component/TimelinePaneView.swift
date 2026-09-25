//
//  TimelinePaneView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TimelineViews.swift` (`TimelinePane`, `SubTaskStrip`). Follow-live
//  defaults to on and stays local `@State` per the screen shape's own allowance — the VM never owns
//  it. Reuses the package-root `TimelineRow`/`TimelineRowModel` shared with the Parallel screen.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - TimelinePaneModel

struct TimelinePaneModel {
    let stepCountText: String
    let items: [TimelineItem]
    let start: Date?
    let live: Bool
    let emptyText: String?
    let subTaskStrip: SubTaskStripModel?
    
    @MainActor
    static let empty = TimelinePaneModel(stepCountText: "0 steps", items: [], start: nil, live: false, emptyText: nil, subTaskStrip: nil)
}

// MARK: - TimelinePaneView

struct TimelinePaneView: View {
    let model: TimelinePaneModel
    @State private var followLive = true
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.stepCountText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Follow live", isOn: $followLive).toggleStyle(.checkbox).font(.system(size: 11))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if let emptyText = model.emptyText {
                            Text(emptyText).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(model.items) { item in
                            TimelineRow(model: TimelineRowModel(item: item, start: model.start, live: model.live)).id(item.id)
                        }
                        if let subTaskStrip = model.subTaskStrip {
                            SubTaskStripView(model: subTaskStrip)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: model.items.count) { _, _ in
                    if followLive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

// MARK: - SubTaskEntry

/// A child task plus its already-resolved title (`AppModel.title(_:)`'s fallback rule), so this
/// dumb component never has to look one up itself.
struct SubTaskEntry: Identifiable {
    let task: TaskInfo
    let title: String
    var id: String { task.taskID }
}

// MARK: - SubTaskStripModel

struct SubTaskStripModel {
    let children: [SubTaskEntry]
    let start: Date?
    let onSelectTask: (String) -> Void
}

// MARK: - SubTaskStripView

struct SubTaskStripView: View {
    let model: SubTaskStripModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Started \(model.children.count) sub-task\(model.children.count == 1 ? "" : "s") via polybridge").font(.system(size: 12, weight: .medium))
            ForEach(model.children) { entry in
                Button {
                    model.onSelectTask(entry.task.taskID)
                } label: {
                    HStack(spacing: 8) {
                        BackendBadge(backend: entry.task.backend, size: 18)
                        Text(entry.title).lineLimit(1)
                        FreedomBadge(freedom: entry.task.freedom)
                        Spacer()
                        Text(entry.task.status.label).foregroundStyle(StatusColor.of(entry.task.status))
                        Text(Format.offset(entry.task.startedAt, from: model.start)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

#if DEBUG
#Preview {
    let start = Date.now.addingTimeInterval(-30)
    TimelinePaneView(model: TimelinePaneModel(
        stepCountText: "2 steps",
        items: [PreviewFixtures.textItem("Looked at the failing test."), PreviewFixtures.finishedItem()],
        start: start, live: false, emptyText: nil, subTaskStrip: nil
    ))
    .frame(width: 500, height: 400)
}
#endif
