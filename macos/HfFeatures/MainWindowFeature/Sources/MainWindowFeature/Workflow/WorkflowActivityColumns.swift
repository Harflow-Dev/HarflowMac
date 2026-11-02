import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowStepPalette

/// The drag-only step tray's presentation grouping: the agent steps first, a hairline divider,
/// then the structural steps. Every one of `WorkflowRole.palette`'s eight roles appears exactly
/// once; the order inside each group follows the palette. Pure and testable — the palette's own
/// definition is untouched.
enum WorkflowStepPalette {
    static let structuralRoles: Set<String> = ["start", "parallel_group", "end"]

    enum Item: Equatable, Identifiable {
        case role(String)
        case divider

        var id: String {
            switch self {
            case let .role(role): role
            case .divider: "divider"
            }
        }

        var role: String? {
            if case let .role(role) = self { return role }
            return nil
        }
    }

    static func items() -> [Item] {
        let agentRoles = WorkflowRole.palette.filter { !structuralRoles.contains($0) }
        let structuralSteps = WorkflowRole.palette.filter { structuralRoles.contains($0) }
        return (agentRoles.map(Item.role)) + [.divider] + (structuralSteps.map(Item.role))
    }
}

// MARK: - WorkflowActivityColumns

/// Reuses the actual Parallel renderer and models; workflow task associations only choose members.
struct WorkflowActivityColumns: View {
    let columns: [ParallelColumnModel]
    let selectedTaskID: String?
    private var horizontalPosition: ParallelViewportPosition?
    /// True only while existing activations prove no worker step has started. When a step has
    /// started but its activity columns are still empty, the panel stays an honest empty card —
    /// no prestart placeholder and no invented loading or unavailable copy.
    var showsPrestartPlaceholder = true
    private let onViewport: (CGFloat, CGFloat) -> Void
    private let stateForColumn: (String) -> ParallelColumnUIState

    init(viewModel: any ParallelViewModel, selectedTaskID: String?, showsPrestartPlaceholder: Bool = true) {
        self.horizontalPosition = viewModel.horizontalPosition
        self.columns = viewModel.columns
        self.selectedTaskID = selectedTaskID
        self.showsPrestartPlaceholder = showsPrestartPlaceholder
        self.onViewport = { viewModel.updateViewport(offset: $0, width: $1) }
        self.stateForColumn = viewModel.columnState(for:)
    }

    init(columns: [ParallelColumnModel], selectedTaskID: String?, showsPrestartPlaceholder: Bool = true) {
        self.columns = columns
        self.selectedTaskID = selectedTaskID
        self.showsPrestartPlaceholder = showsPrestartPlaceholder
        self.onViewport = { _, _ in }
        let states = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, ParallelColumnUIState()) })
        self.stateForColumn = { states[$0] ?? ParallelColumnUIState() }
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollViewReader { scroll in
                ScrollView(.horizontal) {
                    Group {
                        if columns.isEmpty {
                            if showsPrestartPlaceholder {
                                Text("Activity appears here when a node starts.")
.font(.hf(.body))
.foregroundStyle(Color.tertiaryText)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                            } else {
                                Color.cardFill
.opacity(0)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                            }
                        } else {
                            ParallelColumnsContent(columns: columns, availableSize: proxy.size,
                                                   horizontalPosition: horizontalPosition, explicitNavigationID: selectedTaskID,
                                                   stateForColumn: stateForColumn, onViewport: onViewport)
                        }
                    }
                    // The document probe (§6.4): inside the activity lane's own document, so it
                    // can only ever target this horizontal scroll view, empty or populated.
                    .background(ScrollChrome())
                }
                .onChange(of: selectedTaskID) { _, id in if let id {
                    scroll.scrollTo(columns.first { $0.memberTaskIDs.contains(id) || $0.task.taskID == id }?.id ?? id, anchor: .leading)
                } }
            }
        }
    }
}

#if DEBUG
#Preview("Workflow activity uses Parallel") {
    WorkflowActivityColumns(columns: ParallelViewModelMock().columns, selectedTaskID: nil)
        .frame(width: HfRadius.Metrics.foundationWidth,
                height: HfRadius.Metrics.workflowInspectorMaximumWidth)
        .preferredColorScheme(.light)
}

#Preview("Workflow activity uses Parallel - dark") {
    WorkflowActivityColumns(columns: ParallelViewModelMock().columns, selectedTaskID: nil)
        .frame(width: HfRadius.Metrics.foundationWidth,
                height: HfRadius.Metrics.workflowInspectorMaximumWidth)
        .preferredColorScheme(.dark)
}

#Preview("Workflow activity - proven prestart, light") {
    WorkflowActivityColumns(columns: [], selectedTaskID: nil, showsPrestartPlaceholder: true)
        .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.workflowCanvasMinimumWidth)
        .background(Color.cardFill)
        .preferredColorScheme(.light)
}

#Preview("Workflow activity - started but empty") {
    WorkflowActivityColumns(columns: [], selectedTaskID: nil, showsPrestartPlaceholder: false)
        .frame(width: HfRadius.Metrics.foundationWidth, height: HfRadius.Metrics.workflowCanvasMinimumWidth)
        .background(Color.cardFill)
        .preferredColorScheme(.dark)
}
#endif
