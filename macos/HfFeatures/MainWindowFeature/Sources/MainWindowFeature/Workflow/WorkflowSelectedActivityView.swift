import HfUI
import SwiftUI

// MARK: - WorkflowSelectedActivityView

/// A single retained conversation fits the inspector; its feed owns vertical scrolling.
struct WorkflowSelectedActivityView: View {
    var activity: ParallelVM
    @State private var residencyHandoffs = ParallelResidencyHandoffStore()

    var body: some View {
        VStack(spacing: 0) {
            if activity.columns.count > 1 {
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
            GeometryReader { viewport in
                if let column = activity.columns.first(where: { $0.id == activity.selectedConversationID }) {
                    ParallelColumnCell(model: column,
                                       state: column.isResident ? activity.columnState(for: column.id) : nil,
                                       residencyState: residencyHandoffs.state(for: column.id),
                                       size: CGSize(width: max(0, viewport.size.width - ParallelLayout.dividerWidth),
                                                    height: max(0, viewport.size.height)))
                        .equatable()
                        .id(column.id)
                } else {
                    ContentUnavailableView("Activity unavailable", systemImage: "text.alignleft",
                                           description: Text("The task record is not available."))
                }
                Color.clear
                    .allowsHitTesting(false)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        activity.updateViewport(offset: 0, width: width)
                    }
            }
        }
        .onChange(of: activity.columns.map(\.id), initial: true) { _, ids in residencyHandoffs.retain(ids: Set(ids)) }
        .onDisappear { activity.updateViewport(offset: 0, width: 0) }
    }
}

#if DEBUG
#Preview { WorkflowSelectedSidebar(viewModel: WorkflowPreview.make(run: true)) }
#endif
