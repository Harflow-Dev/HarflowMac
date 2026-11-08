//
//  InspectorView.swift
//  MainWindowFeature
//
//  Ported from the app target's `InspectorView.swift`. "Now" reads the timeline's current running
//  tool; "Details"/"Enforcement" read the raw snapshot (falling back to the listing). "Files
//  changed" (git) and the "Branch" row are gone (piece 2/3 of the Monitor architecture plan — see
//  the summary's "Files edited" section instead).
//
//  Redesign phase 5 (settled plan D14/D17): the plain "Details" (Agent, Access, Started, Started
//  by) and the copy buttons come first; everything the old panel showed — session, lineage, limits,
//  enforcement, notices — sits in a collapsed "Technical info" disclosure. The whole inspector is
//  hidden by default (`TaskDetailView` owns that toggle).
//

import HfUI
import MonitorCore
import SwiftUI

// MARK: - InspectorModel

struct InspectorModel {
    let task: TaskInfo
    let current: TimelineItem?
    let stepCount: Int
    let activity: ActivityCounts
    var activityNote: String?
    let subtaskCount: Int
    let ancestors: [SubTaskEntry]
    let siblings: [SubTaskEntry]
    let detail: TaskInfo
    let hasSnapshot: Bool
    var restartHistory: [TaskSupervision.RestartObservation] = []

    var showsContinuity: Bool { task.status.isRunning && detail.status.isRunning && detail.supervision?.hasHealthyContinuity == true }
    let notices: [String]
    /// What harflow reports as enforced (`HfUI.EnforcementText.lines(_:)`, mapped in the VM from
    /// the snapshot-or-listing `detail`) — moved here from the summary (item 15). Empty when
    /// nothing was reported; defaults so call sites that read a bare task (previews, older tests)
    /// keep building.
    var enforcementLines: [String] = []
    /// The parent task's title when one is recorded, else "Top-level task" (D17).
    let startedBy: String
    /// `nil` hides the "Copy resume command" button.
    let resumeCommand: String?
    let onCopyResumeCommand: () -> Void
    let onCopyTaskID: () -> Void
    let onSelectTask: (String) -> Void

    /// "What was enforced" shows only once there are lines to list or a settled snapshot carried
    /// none — never while the snapshot itself hasn't loaded (item 15 moved the section here from
    /// the summary).
    var showsEnforcement: Bool {
        !enforcementLines.isEmpty || InspectorModel.showsEnforcementNotRecorded(detail: detail, hasSnapshot: hasSnapshot)
    }

    /// The "Started by" value: the parent's title when the task was started by another task.
    static func startedByText(parentTitle: String?) -> String {
        parentTitle ?? "Top-level task"
    }

    /// "Enforcement was not recorded for this task." only once a snapshot exists but carried no
    /// enforcement data — never while the snapshot itself hasn't loaded.
    static func showsEnforcementNotRecorded(detail: TaskInfo, hasSnapshot: Bool) -> Bool {
        detail.enforcement == nil && hasSnapshot
    }

    /// `notices` with repeats removed, first occurrence kept — a resumed run often reports the same
    /// environment warning once per turn.
    static func distinctNotices(_ notices: [String]) -> [String] {
        var seen: Set<String> = []
        return notices.filter { seen.insert($0).inserted }
    }
}

typealias InspectorView = TaskSnapshotFactsView

// MARK: - TaskSnapshotFactsView

struct TaskSnapshotFactsView: View {
    let model: InspectorModel?
    var supervisionRequest = 0
    @State private var technicalExpanded = false
    @FocusState private var supervisionFocused: Bool
    @AccessibilityFocusState private var supervisionAccessibilityFocused: Bool

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            if let model {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        section("Task snapshot") { basics(model) }
                        Divider()
                        actions(model)
                    }
                    if !model.notices.isEmpty { notices(model) }
                    DisclosureGroup(isExpanded: $technicalExpanded) {
                        // macOS centres a DisclosureGroup's content unless it is given the full width.
                        technicalInfo(model).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        SectionLabel(text: "Technical info")
                    }
                }
                .padding(20)
                // The document probe (§6.2): inside the task inspector's own document.
                .background(ScrollChrome())
            }
        }
        .background(Color.inspectorFill)
        .onChange(of: supervisionRequest, initial: true) { _, request in
            guard request > 0 else { return }
            technicalExpanded = true
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo("supervision", anchor: .top)
                supervisionFocused = true
                supervisionAccessibilityFocused = true
            }
        }
        }
    }

    @ViewBuilder
    private func now(_ model: InspectorModel) -> some View {
        section("Now") {
            if let current = model.current, case .tool(let call, _) = current.body {
                Text(call.tool).font(.hf(.body, weight: .medium))
                Text(call.headline).font(.hf(.secondary, design: .monospaced)).foregroundStyle(Color.secondaryText).lineLimit(3)
                if let startedAt = current.at {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(Format.clock(context.date.timeIntervalSince(startedAt))) · activity item \(model.stepCount)")
                            .font(.hf(.caption))
                            .monospacedDigit()
                            .foregroundStyle(Color.secondaryText)
                    }
                }
            } else {
                Text("Thinking or writing").font(.hf(.body)).foregroundStyle(Color.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func basics(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                InspectorSections.detailName("Harness")
                Spacer(minLength: 8)
                BackendLabel(backend: model.task.backend).font(.hf(.secondary))
            }
            InspectorSections.detailRow("Access level", model.task.freedom.map { AccessLabel.text(freedom: $0) } ?? "—")
            InspectorSections.detailRow("Started", Format.time(model.task.startedAt))
            InspectorSections.detailRow("Started by", model.startedBy)
        }
    }

    @ViewBuilder
    private func actions(_ model: InspectorModel) -> some View {
        VStack(spacing: 8) {
            if model.resumeCommand != nil {
                Button(action: model.onCopyResumeCommand) {
                    Label("Copy resume command", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
            }
            Button(action: model.onCopyTaskID) {
                Text("Copy task ID").frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(QuietButtonStyle(isFilled: false))
    }

    @ViewBuilder
    private func technicalInfo(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(text: "Supervision")
                    .focusable()
                    .focused($supervisionFocused)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityFocused($supervisionAccessibilityFocused)
                InspectorSections.supervision(model)
            }
            .id("supervision")
            section("Details") { InspectorSections.details(model) }
            if !model.task.isRoot { InspectorSections.lineage(model) }
            if model.showsEnforcement { section("What was enforced") { enforcement(model) } }
        }
    }

    /// "What was enforced" (item 15: the section moved here): the plain
    /// `HfUI.EnforcementText` sentences, plus the not-recorded note once a snapshot settled
    /// without any enforcement data.
    private func enforcement(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.enforcementLines, id: \.self) { line in
                Text(line).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            }
            if InspectorModel.showsEnforcementNotRecorded(detail: model.detail, hasSnapshot: model.hasSnapshot) {
                Text("Enforcement was not recorded for this task.")
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }

    /// Notices the run reported (environment warnings, dispatch notes). They live here rather than
    /// above the activity; the header only shows a count that opens this panel.
    private func notices(_ model: InspectorModel) -> some View {
        section("Notices") {
            ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.warningFG)
                    Text(notice).font(.hf(.secondary)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        InspectorSections.section(title, content: content)
    }
}

#if DEBUG
@MainActor
private func previewModel(status: String, isRoot: Bool, enforcement: Bool = true) -> InspectorModel {
    let task = TaskDetailViewModelMock.sampleTask(status: status, spawnedBy: isRoot ? nil : "parent01")
    var activity = ActivityCounts()
    activity.toolCalls = 12
    activity.edits = 2
    activity.commands = 3
    return InspectorModel(
        task: task, current: nil, stepCount: 4,
        activity: activity, subtaskCount: 1,
        ancestors: [], siblings: [], detail: task, hasSnapshot: true, notices: ["Approaching the turn limit."],
        enforcementLines: enforcement
            ? ["Restrictions enforced by the OS sandbox", "Git commit and push blocked"]
            : [],
        startedBy: InspectorModel.startedByText(parentTitle: isRoot ? nil : "Refactor the sidebar"),
        resumeCommand: "cd /repo && claude --resume abc", onCopyResumeCommand: {}, onCopyTaskID: {}, onSelectTask: { _ in }
    )
}

#Preview("Running - light") {
    InspectorView(model: previewModel(status: "running", isRoot: true))
        .frame(width: 280, height: 560)
        .preferredColorScheme(.light)
}

#Preview("Sub-task - dark") {
    InspectorView(model: previewModel(status: "completed", isRoot: false))
        .frame(width: 280, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("No enforcement recorded - light") {
    InspectorView(model: previewModel(status: "completed", isRoot: true, enforcement: false))
        .frame(width: 280, height: 560)
        .preferredColorScheme(.light)
}

#Preview("No enforcement recorded - dark") {
    InspectorView(model: previewModel(status: "completed", isRoot: true, enforcement: false))
        .frame(width: 280, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("Empty - light") {
    InspectorView(model: nil).frame(width: 280, height: 200).preferredColorScheme(.light)
}

#Preview("Empty - dark") {
    InspectorView(model: nil).frame(width: 280, height: 200).preferredColorScheme(.dark)
}
#endif
