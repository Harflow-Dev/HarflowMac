import MonitorCore
import PbUI
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

// MARK: - WorkflowStepFlowLayout

/// A wrapping row layout for the glass step tray: chips keep their intrinsic sizes and wrap to
/// new rows at the band's actual width, so every role stays reachable at any width with no
/// horizontal scrollbar and a measured (not guessed) band height.
struct WorkflowStepFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widestRow: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                widestRow = max(widestRow, x - spacing)
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        widestRow = max(widestRow, max(0, x - spacing))
        return CGSize(width: proposal.width ?? widestRow, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - WorkflowActivityColumns

/// Reuses the actual Parallel renderer and models; workflow task associations only choose members.
struct WorkflowActivityColumns: View {
    let columns: [ParallelColumnModel]
    let selectedTaskID: String?
    /// True only while existing activations prove no worker step has started. When a step has
    /// started but its activity columns are still empty, the panel stays an honest empty card —
    /// no prestart placeholder and no invented loading or unavailable copy.
    var showsPrestartPlaceholder = true
    private let onViewport: (CGFloat, CGFloat) -> Void
    private let stateForColumn: (String) -> ParallelColumnUIState

    init(viewModel: any ParallelViewModel, selectedTaskID: String?, showsPrestartPlaceholder: Bool = true) {
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
                                Text("Agent activity appears here when a step starts.")
.font(.pb(.body))
.foregroundStyle(Color.tertiaryText)
                                .frame(width: proxy.size.width, height: proxy.size.height)
                            } else {
                                Color.cardFill
.opacity(0)
                                    .frame(width: proxy.size.width, height: proxy.size.height)
                            }
                        } else {
                            ParallelColumnsContent(columns: columns, availableSize: proxy.size,
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
        .frame(width: PbRadius.Metrics.foundationWidth,
                height: PbRadius.Metrics.workflowInspectorMaximumWidth)
        .preferredColorScheme(.light)
}

#Preview("Workflow activity uses Parallel - dark") {
    WorkflowActivityColumns(columns: ParallelViewModelMock().columns, selectedTaskID: nil)
        .frame(width: PbRadius.Metrics.foundationWidth,
                height: PbRadius.Metrics.workflowInspectorMaximumWidth)
        .preferredColorScheme(.dark)
}

#Preview("Workflow activity - proven prestart, light") {
    WorkflowActivityColumns(columns: [], selectedTaskID: nil, showsPrestartPlaceholder: true)
        .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.workflowCanvasMinimumWidth)
        .background(Color.cardFill)
        .preferredColorScheme(.light)
}

#Preview("Workflow activity - started but empty") {
    WorkflowActivityColumns(columns: [], selectedTaskID: nil, showsPrestartPlaceholder: false)
        .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.workflowCanvasMinimumWidth)
        .background(Color.cardFill)
        .preferredColorScheme(.dark)
}
#endif
