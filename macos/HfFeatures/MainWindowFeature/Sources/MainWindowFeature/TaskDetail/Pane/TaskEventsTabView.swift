//
//  TaskEventsTabView.swift
//  MainWindowFeature
//
//  The standalone pane's Events tab: facts groups on top (collapsed unless revealed), then the public events
//  content exactly as before. Reading position is kept as a scroll offset in `TaskPaneStateStore`, so it
//  survives a close, a tab switch and the coordinator's per-conversation view reset.
//

import HfUI
import MonitorCore
import SwiftUI

// MARK: - TaskEventsTabView

/// Facts groups, then `PublicEventsView`. Generic over the screen's view model like `TaskDetailView`.
struct TaskEventsTabView<VM: TaskDetailViewModel>: View {
    let viewModel: VM
    let pane: TaskPaneController
    let focus: TaskPaneFocus

    @State private var position = ScrollPosition()
    /// False until the stored offset has been restored, so the initial layout cannot overwrite it with zero.
    @State private var tracksOffset = false
    /// The deferred reveal work, cancelled when a newer request arrives or the tab disappears.
    @State private var revealTask: Task<Void, Never>?
    /// The deferred end of offset restoration, cancelled when the tab disappears.
    @State private var restoreTask: Task<Void, Never>?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: TaskScreenStyle.PaneBody.gap) {
                    taskGroup
                    enforcementGroup
                    noticesGroup
                    continuityGroup
                    usageGroup
                    PublicEventsView(frame: viewModel.task.flatMap { viewModel.observationFrames[$0.taskID] },
                                     recovered: viewModel.recoveredTranscript, copy: viewModel.didCopyObservationText)
                        .padding(.top, TaskScreenStyle.FactsBody.headingMarginTop)
                }
                .padding(TaskScreenStyle.PaneBody.padding)
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, offset in
                if tracksOffset { pane.recordEventsScrollOffset(max(0, offset)) }
            }
            .onAppear { restoreOffset() }
            .onChange(of: pane.focusRequest, initial: true) { _, request in
                guard let request else { return }
                revealTask?.cancel()
                revealTask = Task { @MainActor in
                    await Task.yield()
                    // The request may have been superseded, cancelled, or the pane closed or switched tab meanwhile.
                    guard !Task.isCancelled, pane.isCurrentReveal(token: request.token) else { return }
                    withAnimation(nil) { proxy.scrollTo(request.group, anchor: .top) }
                    focus.group.wrappedValue = request.group
                    focus.accessibilityGroup.wrappedValue = request.group
                    pane.consumeFocusRequest(token: request.token)
                }
            }
            .onDisappear {
                revealTask?.cancel()
                revealTask = nil
                restoreTask?.cancel()
                restoreTask = nil
            }
        }
    }

    private func restoreOffset() {
        guard pane.focusRequest == nil, let offset = pane.eventsScrollOffset, offset > 0 else {
            tracksOffset = true
            return
        }
        position.scrollTo(y: offset)
        restoreTask?.cancel()
        restoreTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            tracksOffset = true
        }
    }

    private func isExpanded(_ group: TaskPaneStateStore.FactsGroup) -> Bool { pane.expandedGroups.contains(group) }

    private func group(_ group: TaskPaneStateStore.FactsGroup, _ title: String, count: Int? = nil,
                       @ViewBuilder content: @escaping () -> some View) -> some View {
        FactsGroupView(group: group, title: title, count: count, isExpanded: isExpanded(group),
                       setExpanded: { pane.setGroup(group, expanded: $0) }, focus: focus, content: content)
    }
}

// MARK: - Groups

private extension TaskEventsTabView {

    /// Status, exit, harness, repository, turns, the task id with its copy action, the taken-over note and the
    /// snapshot's remaining rows and actions.
    @ViewBuilder var taskGroup: some View {
        if let task = viewModel.task {
            group(.task, "Task") {
                VStack(alignment: .leading, spacing: TaskScreenStyle.FactsBody.listMarginVertical) {
                    FactsGrid {
                        factsRow("Status", TaskFactsText.status(task))
                        factsRow("Exit", viewModel.snapshotEvidence?.exitText ?? "—")
                        factsRow("Harness", TaskFactsText.harness(task: task, model: viewModel.inspectorModel))
                        factsRow("Repository", TaskFactsText.repository(task), help: task.repoPath)
                        factsRow("Turns", TaskFactsText.turns(viewModel.turnsText))
                        if let freedom = task.freedom { factsRow("Access level", AccessLabel.text(freedom: freedom)) }
                        factsRow("Started", Format.time(task.startedAt))
                        if let model = viewModel.inspectorModel { factsRow("Started by", model.startedBy) }
                        taskIDRow(task)
                        if let note = task.takenOverNote ?? viewModel.takenOverBannerText { factsRow("Taken over", note) }
                    }
                    if let provenance = viewModel.spawnedByBannerText {
                        Text(provenance)
                            .foregroundStyle(TaskScreenStyle.Colors.text.color)
                            .textSelection(.enabled)
                    }
                    if viewModel.resumeCommand != nil {
                        Button("Copy resume command", action: viewModel.didTapCopyResumeCommand)
                            .buttonStyle(QuietButtonStyle(isFilled: false))
                    }
                    technicalInfo
                }
            }
        }
    }

    func taskIDRow(_ task: TaskInfo) -> some View {
        GridRow {
            Text("Task ID").foregroundStyle(TaskScreenStyle.FactsBody.termColor.color)
            HStack(alignment: .firstTextBaseline, spacing: TaskScreenStyle.Scale.space2) {
                Text(verbatim: task.taskID)
                    .font(TaskScreenStyle.mono(size: TaskScreenStyle.FactsBody.listText.size))
                    .foregroundStyle(TaskScreenStyle.Colors.text.color)
                    .textSelection(.enabled)
                Button("Copy task ID", action: viewModel.didTapCopyTaskID)
                    .buttonStyle(.link)
            }
        }
    }

    /// The old "Task snapshot facts" disclosure's remaining content: supervision (unless Continuity shows it),
    /// task details, lineage and limits.
    @ViewBuilder var technicalInfo: some View {
        if let model = viewModel.inspectorModel {
            DisclosureGroup(isExpanded: Binding(get: { pane.technicalInfoExpanded }, set: { pane.setTechnicalInfoExpanded($0) })) {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing24) {
                    if !model.showsContinuity {
                        InspectorSections.section("Supervision") { InspectorSections.supervision(model) }
                    }
                    InspectorSections.section("Details") { InspectorSections.details(model) }
                    if !model.task.isRoot { InspectorSections.lineage(model) }
                }
                .padding(.top, HfRadius.Metrics.spacing8)
                .frame(maxWidth: .infinity, alignment: .leading)
            } label: {
                SectionLabel(text: "Technical info")
            }
        }
    }

    @ViewBuilder var enforcementGroup: some View {
        if let model = viewModel.inspectorModel, model.showsEnforcement {
            group(.enforcement, "What was enforced") {
                VStack(alignment: .leading, spacing: TaskScreenStyle.FactsBody.listMarginVertical) {
                    ForEach(model.enforcementLines, id: \.self) { line in
                        Text(line).foregroundStyle(TaskScreenStyle.Colors.text.color)
                    }
                    if InspectorModel.showsEnforcementNotRecorded(detail: model.detail, hasSnapshot: model.hasSnapshot) {
                        Text("Enforcement was not recorded for this task.").foregroundStyle(TaskScreenStyle.Colors.text.color)
                    }
                    FactsCaption(text: TaskFactsText.enforcementCaption)
                }
            }
        }
    }

    @ViewBuilder var noticesGroup: some View {
        if let model = viewModel.inspectorModel {
            group(.notices, "Notices", count: model.notices.isEmpty ? nil : model.notices.count) {
                if model.notices.isEmpty {
                    FactsCaption(text: "No notices.")
                } else {
                    VStack(alignment: .leading, spacing: TaskScreenStyle.FactsBody.rowGap) {
                        ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
                            HStack(alignment: .top, spacing: HfRadius.Metrics.spacing6) {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.warningFG).accessibilityHidden(true)
                                Text(notice).foregroundStyle(TaskScreenStyle.Colors.text.color).textSelection(.enabled)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder var continuityGroup: some View {
        if let model = viewModel.inspectorModel, model.showsContinuity {
            group(.continuity, "Continuity") {
                VStack(alignment: .leading, spacing: TaskScreenStyle.FactsBody.listMarginVertical) {
                    Text(TaskFactsText.continuityText).foregroundStyle(TaskScreenStyle.Colors.text.color)
                    FactsCaption(text: TaskFactsText.continuityCaption)
                    InspectorSections.section("Supervision") { InspectorSections.supervision(model) }
                        .padding(.top, HfRadius.Metrics.spacing8)
                }
            }
        }
    }

    /// The reported result, cost and usage, permission denials and Files edited, unchanged and collapsed until
    /// the design classifies them. Artifacts live in their own tab, so none are passed here. While the transcript
    /// ends with the Summary entry, the group drops the hero and the Result it would repeat and reads "Reported
    /// usage"; its identity, expansion and frame are unchanged.
    var usageGroup: some View {
        let entryShown = viewModel.summaryEntryShown
        return group(.usage, entryShown ? "Reported usage" : "Reported result and usage") {
            SummaryPaneView(model: viewModel.summaryModel, showsHeroAndResult: !entryShown).frame(height: Self.usageHeight)
        }
    }

    private static var usageHeight: CGFloat { 360 }
}
