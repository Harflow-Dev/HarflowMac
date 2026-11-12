//
//  ParallelColumnView+Previews.swift
//  MainWindowFeature
//
//  Xcode previews of `ParallelColumnView`.
//

import HfUI
import MonitorCore
import SwiftUI

#if DEBUG
private func previewTask(id: String, age: TimeInterval, status: String = "running") -> TaskInfo {
    TaskInfo(.object([
        "task_id": .string(id), "backend": .string("claude"), "status": .string(status), "repo_path": .string("/Users/me/Code/harflow"),
        "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-age)))
    ]))!
}

@MainActor
private func previewColumn(_ model: ParallelColumnModel) -> some View {
    ParallelColumnView(model: model)
        .frame(width: HfRadius.Metrics.parallelColumnPreviewWidth, height: HfRadius.Metrics.parallelColumnPreviewHeight)
        .background(Color.windowBG)
}

@MainActor
private func columnModel(
    id: String = "abc123", task: TaskInfo, rows: [ConversationTimelineRow], isLoading: Bool = false, turns: Int = 1,
    summary: String? = nil, liveStep: LiveStep? = nil
) -> ParallelColumnModel {
    ParallelColumnModel(
        id: id, task: task, title: "Fix the login bug",
        subtitle: ParallelColumnModel.subtitle(repoPath: "/Users/me/Code/harflow", backend: task.backend, turns: turns),
        isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
        rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), liveStep: liveStep ?? LiveStep(rows: rows), isLoading: isLoading,
        summary: summary, onTapTakeover: {}, onTapOpenTask: {}
    )
}

private var followUpRows: [ConversationTimelineRow] {
    [
        ConversationTimelineRow(
            id: "t1#1", taskID: "t1", timestamp: .now.addingTimeInterval(-90),
            kind: .item(PreviewFixtures.textItem("Looked at the failing test.")), live: false
        ),
        ConversationTimelineRow(
            id: "sep:t2", taskID: "t2", timestamp: .now,
            kind: .separator(text: "Also add a test for the edge case"), live: false
        ),
        ConversationTimelineRow(id: "t2#1", taskID: "t2", timestamp: .now, kind: .item(PreviewFixtures.finishedItem()), live: true)
    ]
}

#Preview("Running - light") {
    previewColumn(columnModel(task: previewTask(id: "abc123", age: 90), rows: PreviewFixtures.sampleRows(taskID: "abc123")))
        .preferredColorScheme(.light)
}

#Preview("Running - dark") {
    previewColumn(columnModel(task: previewTask(id: "abc123", age: 90), rows: PreviewFixtures.sampleRows(taskID: "abc123")))
        .preferredColorScheme(.dark)
}

#Preview("Finished - light") {
    previewColumn(columnModel(
        task: previewTask(id: "abc123", age: 90, status: "completed"), rows: PreviewFixtures.sampleRows(taskID: "abc123", running: false),
        summary: "Fixed the **flaky** login test by warming the keychain first."
    ))
    .preferredColorScheme(.light)
}

#Preview("Finished - dark") {
    previewColumn(columnModel(
        task: previewTask(id: "abc123", age: 90, status: "completed"), rows: PreviewFixtures.sampleRows(taskID: "abc123", running: false),
        summary: "Fixed the **flaky** login test by warming the keychain first."
    ))
    .preferredColorScheme(.dark)
}

#Preview("Long result - light") {
    previewColumn(longResultColumnModel()).preferredColorScheme(.light)
}

#Preview("Long result - dark") {
    previewColumn(longResultColumnModel()).preferredColorScheme(.dark)
}

@MainActor
private func longResultColumnModel() -> ParallelColumnModel {
    columnModel(task: previewTask(id: "abc123", age: 90, status: "completed"),
                rows: PreviewFixtures.sampleRows(taskID: "abc123", running: false),
                summary: Array(repeating: "The completed review includes a detailed result that remains scrollable above activity.", count: 20)
                    .joined(separator: "\n\n"))
}

#Preview("Loading column - light") {
    previewColumn(columnModel(task: previewTask(id: "abc123", age: 2), rows: [], isLoading: true)).preferredColorScheme(.light)
}

#Preview("Loading column - dark") {
    previewColumn(columnModel(task: previewTask(id: "abc123", age: 2), rows: [], isLoading: true)).preferredColorScheme(.dark)
}

#Preview("With a follow-up turn - light") {
    previewColumn(columnModel(id: "t1", task: previewTask(id: "t2", age: 90), rows: followUpRows, turns: 2))
        .preferredColorScheme(.light)
}

#Preview("With a follow-up turn - dark") {
    previewColumn(columnModel(id: "t1", task: previewTask(id: "t2", age: 90), rows: followUpRows, turns: 2))
        .preferredColorScheme(.dark)
}

#Preview("Prose-only, no tools recorded - light") {
    previewColumn(noToolsColumnModel())
        .preferredColorScheme(.light)
}

#Preview("Prose-only, no tools recorded - dark") {
    previewColumn(noToolsColumnModel())
        .preferredColorScheme(.dark)
}

#Preview("Live activity, three dots - light") {
    previewColumn(liveStepColumnModel()).preferredColorScheme(.light)
}

#Preview("Live activity, three dots - dark") {
    previewColumn(liveStepColumnModel()).preferredColorScheme(.dark)
}

@MainActor
private func noToolsColumnModel() -> ParallelColumnModel {
    // A complete, settled, prose-only turn: the count reads "1 activity item" and the proven
    // "No tool calls recorded" note shows beside it.
    let rows = [ConversationTimelineRow(
        id: "abc123#1", taskID: "abc123", timestamp: .now.addingTimeInterval(-30),
        kind: .item(PreviewFixtures.textItem("Reviewed the diff and left one comment.")), live: false
    )]
    var model = columnModel(task: previewTask(id: "abc123", age: 30, status: "completed"), rows: rows)
    model.stepCountText = "1 activity item"
    model.noToolCallsText = "No tool calls recorded"
    return model
}

@MainActor
private func liveStepColumnModel() -> ParallelColumnModel {
    let rows = PreviewFixtures.sampleRows(taskID: "abc123")
    var model = columnModel(task: previewTask(id: "abc123", age: 10), rows: rows,
                            liveStep: LiveStep(rows: rows, isRunning: true))
    model.stepCountText = "6 activity items"
    return model
}
#endif
