import HfUI
import SwiftUI

// MARK: - WorkflowRunSummary

/// The fixed collapsed strip anchors an upward overlay without resizing the graph viewport.
struct WorkflowRunSummary<VM: WorkflowViewModel>: View {
    var viewModel: VM
    @Binding var isExpanded: Bool
    let maximumHeight: CGFloat
    var isRecoveryPanelVisible = false

    var body: some View {
        header
            .frame(height: 36)
            .background(Color.cardFill)
            .opacity(isExpanded ? 0 : 1)
            .allowsHitTesting(!isExpanded)
            .accessibilityHidden(isExpanded)
            .overlay(alignment: .bottom) {
                if isExpanded {
                    VStack(spacing: 0) {
                        header
                        Divider()
                        ScrollView {
                            WorkflowRunStatus(viewModel: viewModel, isRecoveryPanelVisible: isRecoveryPanelVisible)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: maximumHeight)
                    .background(Color.cardFill)
                    .overlay(alignment: .top) { Divider() }
                    .shadow(radius: 8, y: -2)
                    .accessibilityIdentifier("workflow-run-summary-expanded")
                }
            }
            .accessibilityIdentifier("workflow-run-summary")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Summary").font(.hf(.secondary, weight: .semibold))
            Text(hidesDuplicateQuestion ? "" : preview)
.font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                .lineLimit(1)
.truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .opacity(hidesDuplicateQuestion ? 0 : 1)
                .accessibilityHidden(hidesDuplicateQuestion)
            Button(isExpanded ? "Collapse summary" : "Expand summary", systemImage: isExpanded ? "chevron.down" : "chevron.up") {
                isExpanded.toggle()
            }
.labelStyle(.iconOnly)
                .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
    }

    private var preview: String {
        guard let run = viewModel.selectedRun else { return "Loading workflow…" }
        return run.reason.isEmpty ? run.status.replacingOccurrences(of: "_", with: " ") : run.reason
    }

    private var hidesDuplicateQuestion: Bool {
        guard isRecoveryPanelVisible, let run = viewModel.selectedRun else { return false }
        let question = run.question.trimmingCharacters(in: .whitespacesAndNewlines)
        return !question.isEmpty && preview.trimmingCharacters(in: .whitespacesAndNewlines) == question
    }
}

#if DEBUG
#Preview { WorkflowRunSummary(viewModel: WorkflowPreview.make(run: true), isExpanded: .constant(false), maximumHeight: 300) }
#endif
