import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowSelectedActivityView

/// A single retained conversation fits the inspector; its feed owns vertical scrolling.
struct WorkflowSelectedActivityView: View {
    var activity: ParallelVM
    /// An on-demand call's assignment, reason and result, shown above the placeholder while its conversation cannot be shown.
    var unavailableDetails: WorkflowCallDetails?
    /// True for the orchestrator pane, whose task title and status the pane head does not carry.
    var showsTaskTitle = false
    var fallbackMessages: [WorkMessageBubble] = []
    var onCancelFallbackMessage: ((String) -> Void)?
    var cancelDisabled = false
    @Environment(\.workflowInspectorDocument) private var inspectorDocument
    @Environment(\.workflowInspectorApprovalController) private var approvalController
    @State private var pickerHeight: CGFloat = 0
    @State private var residencyHandoffs = ParallelResidencyHandoffStore()
    /// This instance's claim on the activity viewport. A replaced instance's disappearance must not zero a newer owner's.
    @State private var viewportOwner = UUID()

    var body: some View {
        VStack(spacing: 0) {
            if activity.columns.count > 1 {
                VStack(spacing: 0) {
                Picker("Conversation", selection: Binding(get: { activity.selectedConversationID ?? "" },
                                                          set: { activity.selectConversation($0) })) {
                    ForEach(activity.columns) { column in
                        Text(column.title).tag(column.id)
                    }
                }
                .accessibilityIdentifier("workflow-activity-conversation-picker")
                .padding(12)
                Divider()
                }
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pickerHeight = $0 }
                .preference(key: WorkflowSelectedColumnChromeKey.self, value: WorkflowLayoutHeights(actual: pickerHeight, regular: pickerHeight))
            }
            GeometryReader { viewport in
                if let column = activity.columns.first(where: { $0.id == activity.selectedConversationID }) {
                    ParallelColumnCell(model: column.withChrome(.inspector, showsInspectorTitle: showsTaskTitle),
                                       state: column.isResident ? activity.columnState(for: column.id) : nil,
                                       residencyState: residencyHandoffs.state(for: column.id),
                                       size: CGSize(width: max(0, viewport.size.width - ParallelLayout.dividerWidth),
                                                    height: max(0, viewport.size.height)))
                        .equatable()
                        .id(column.id)
                } else {
                    if inspectorDocument.isEnabled {
                        WorkflowInspectorFiniteDocument(document: inspectorDocument,
                            protectsTrailingContent: fallbackMessages.contains(where: \.isPinned)) {
                            if let unavailableDetails { WorkflowCallDetailsView(details: unavailableDetails, naturalHeight: true) }
                            ContentUnavailableView("Activity unavailable", systemImage: "text.alignleft",
                                description: Text("The task record is not available."))
                            if let approvalController { WorkflowInspectorApprovalCards(controller: approvalController) }
                            WorkMessageBubblesView(bubbles: fallbackMessages, onCancel: onCancelFallbackMessage,
                                                   isCancelDisabled: cancelDisabled)
                        }
                    } else {
                        VStack(spacing: 0) {
                            if let unavailableDetails { WorkflowCallDetailsView(details: unavailableDetails); Divider() }
                            ContentUnavailableView("Activity unavailable", systemImage: "text.alignleft",
                                description: Text("The task record is not available."))
                        }
                    }
                }
                Color.clear
                    .allowsHitTesting(false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        activity.updateViewport(owner: viewportOwner, offset: 0, width: width)
                    }
            }
        }
        .onChange(of: activity.columns.map(\.id), initial: true) { _, ids in residencyHandoffs.retain(ids: Set(ids)) }
        .onAppear { activity.claimViewport(owner: viewportOwner) }
        .onDisappear { activity.releaseViewport(owner: viewportOwner) }
    }
}

#if DEBUG
#Preview { WorkflowSelectedSidebar(viewModel: WorkflowPreview.make(run: true)) }
#endif
