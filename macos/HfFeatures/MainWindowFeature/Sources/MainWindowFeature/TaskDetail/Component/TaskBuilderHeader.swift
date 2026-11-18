import HfUI
import MonitorCore
import SwiftUI

// MARK: - TaskBuilderHeader

/// Builder chrome keeps task facts in the activity column without linking to an absent inspector.
/// All values and actions use the existing task presentation and its authority checks.
struct TaskBuilderHeader<VM: TaskDetailViewModel>: View {
    let viewModel: VM
    let task: TaskInfo
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Workflow builder").font(.hf(.secondary, weight: .semibold))
                Spacer(minLength: 0)
                TaskStatusLabel(task: task)
                if viewModel.isBusy { ProgressView().controlSize(.small) }
                actions
            }
            HStack(spacing: 6) {
                BackendLabel(backend: task.backend)
                if let freedom = task.freedom { Text("· \(AccessLabel.text(freedom: freedom))") }
                if let turns = viewModel.turnsText { Text("· \(turns)") }
            }.foregroundStyle(Color.secondaryText)
            ViewThatFits(in: .vertical) {
                feedback
                ScrollView { feedback }
            }
            .frame(maxHeight: 220, alignment: .top)
        }
        .font(.hf(.secondary))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-builder-header")
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let message = viewModel.outcomeMessage {
                Text(message).foregroundStyle(OutcomeColor.of(message)).textSelection(.enabled)
            }
            if let text = viewModel.takenOverBannerText {
                Banner(icon: "person.fill", title: "Taken over", text: text)
            }
            if let text = viewModel.spawnedByBannerText {
                Banner(icon: "arrow.turn.down.right", title: "Sub-task started by another agent", text: text)
            }
            if let model = viewModel.inspectorModel {
                ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
                    Text(notice).foregroundStyle(Color.warningFG).textSelection(.enabled)
                }
                if model.showsContinuity {
                    Text("Server restarted · Task still running").foregroundStyle(Color.secondaryText)
                    InspectorSections.supervision(model)
                }
            }
            details
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        Menu {
            Button("Copy task ID", action: viewModel.didTapCopyTaskID)
            if viewModel.canCancel {
                Button("Cancel", role: .destructive, action: viewModel.didTapCancel).disabled(viewModel.isBusy)
            }
            if viewModel.resumeCommand != nil {
                Button("Copy resume command", action: viewModel.didTapCopyResumeCommand)
            }
            if let parentID = viewModel.openParentTaskID {
                Button("Open parent") { viewModel.didTapTask(parentID) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("Builder actions")
    }

    private var details: some View {
        DisclosureGroup("Task facts and reported result", isExpanded: $detailsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                TaskSnapshotFactsView(model: viewModel.inspectorModel)
                    .frame(height: 280)
                SummaryPaneView(model: viewModel.summaryModel, showsHeroAndResult: true,
                                artifactMembers: viewModel.artifactMembers,
                                loadArtifacts: { viewModel.didLoadArtifacts(taskID: $0) })
                    .frame(height: 280)
                let frame = viewModel.observationFrames[task.taskID]
                PublicEventsView(frame: frame, recovered: viewModel.recoveredTranscript,
                                 copy: viewModel.didCopyObservationText) {
                    if let frame { viewModel.didRequestObservation($0, taskID: frame.taskID) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
#Preview("Builder task") {
    TaskDetailView(TaskDetailViewModelMock.longTitle(), chrome: .builder)
        .frame(width: 460, height: 700)
}
#endif
