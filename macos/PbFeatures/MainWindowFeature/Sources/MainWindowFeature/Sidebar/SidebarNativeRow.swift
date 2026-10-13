import PbCommon
import PbRepository
import PbUI
import SwiftUI

// MARK: - SidebarNativeActions

/// Stable action ownership lets retained cells invoke the latest view model without root writes.
@MainActor final class SidebarNativeActions {
    var select: (MonitorDestination?) -> Void = { _ in }
    var toggle: (String) -> Void = { _ in }
    var toggleWorkflows: () -> Void = {}
    var newWorkflow: () -> Void = {}
    var primary: () -> Void = {}
    var secondary: () -> Void = {}
    var dismiss: () -> Void = {}
    var loadTasks: () -> Void = {}
    var loadWorkflows: () -> Void = {}
    var move: (MoveCommandDirection) -> Void = { _ in }
    var mounted: (Set<String>) -> Void = { _ in }
    var history: (Bool, Int) -> Void = { _, _ in }
    var viewEvent: Binding<ViewEvent> = .constant(.none)

    var forwardingViewEvent: Binding<ViewEvent> {
        Binding(get: { self.viewEvent.wrappedValue }, set: { self.viewEvent.wrappedValue = $0 })
    }

    func reset() {
        select = { _ in }; toggle = { _ in }; toggleWorkflows = {}; newWorkflow = {}
        primary = {}; secondary = {}; dismiss = {}; loadTasks = {}; loadWorkflows = {}
        move = { _ in }; mounted = { _ in }; history = { _, _ in }
        viewEvent = .constant(.none)
    }
}

// MARK: - SidebarNativeRow

struct SidebarNativeRow: View {
    let entry: SidebarListEntry
    let actions: SidebarNativeActions
    let selected: Bool
    let animate: Bool
    let environment: EnvironmentValues
    let increasedProminence: Bool
    var availableWidth: CGFloat?
    let occupiedHeight: @MainActor @Sendable (CGFloat) -> Void
    var measurementOnly = false

    var resolvedEnvironment: EnvironmentValues {
        var resolved = environment
        resolved.viewEvent = actions.forwardingViewEvent
        resolved.backgroundProminence = increasedProminence ? .increased : .standard
        return resolved
    }

    private var reduceMotion: Bool {
        PbMotion.reduceMotion(override: environment.pbReduceMotionOverride, system: environment.accessibilityReduceMotion)
    }

    private var usesDisclosureBridge: Bool {
        if case .item = entry.content { return !reduceMotion }
        return false
    }

    var body: some View {
        content
            .padding(.horizontal, PbRadius.Metrics.sidebarRowInsetHorizontal)
            .frame(width: availableWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                if !measurementOnly, !usesDisclosureBridge { occupiedHeight($0) }
            }
            .environment(\.self, resolvedEnvironment)
            .id(entry.nativeID)
    }

    @ViewBuilder private var content: some View {
        switch entry.content {
        case .workflowsHeader(let expanded):
            HStack(spacing: PbRadius.Metrics.spacing8) {
                Button(action: { actions.toggleWorkflows() }) { heading("Workflows") }
                    .buttonStyle(.plain)
                    .accessibilityLabel(expanded ? "Collapse workflows" : "Expand workflows")
                Button(action: { actions.newWorkflow() }) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .font(.pb(.caption, weight: .semibold))
                    .foregroundStyle(Color.secondaryText)
                    .accessibilityLabel("New workflow")
                Spacer()
            }
        case .heading(let title):
            heading(title).accessibilityAddTraits(.isHeader)
        case .workflowDefinition(let title):
            SidebarWorkflowDefinitionRow(title: title)
                .font(.pb(.body, weight: .medium))
                .padding(.vertical, PbRadius.Metrics.spacing6)
                .frame(minHeight: entry.minimumHeight)
                .pbFadeIn(animate: animate)
        case .item(let item):
            if measurementOnly {
                itemContent(item).frame(minHeight: entry.minimumHeight)
            } else {
                SidebarDisclosureRow(isVisible: !entry.isFading, animate: animate, minimumHeight: entry.minimumHeight,
                                     onOccupiedHeight: usesDisclosureBridge ? occupiedHeight : nil) {
                    itemContent(item)
                }
                .allowsHitTesting(!entry.isFading)
                .accessibilityHidden(entry.isFading)
            }
        case .banner(let banner):
            InstallBanner(model: banner.model, onPrimary: { actions.primary() },
                          onSecondary: { actions.secondary() }, onDismiss: { actions.dismiss() })
        case .error(let message):
            Text(message).font(.pb(.secondary)).foregroundStyle(Color.failedRed).textSelection(.enabled)
        case .skeleton:
            SkeletonRows()
        case .history(let source, let state):
            historyControl(source, state: state)
        case .empty(let message):
            Text(message)
.font(.pb(.body))
.foregroundStyle(Color.secondaryText)
                .lineLimit(nil)
.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .sentinel:
            Color.clear.frame(height: PbRadius.Metrics.hairlineStroke).accessibilityHidden(true)
        }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.pb(.caption, weight: .semibold)).foregroundStyle(Color.tertiaryText)
    }

    @ViewBuilder private func itemContent(_ item: SidebarItem) -> some View {
        switch item {
        case .task(let row):
            TaskRow(model: row, onToggleExpansion: row.hasChildren ? { actions.toggle(row.id) } : nil,
                    sidebarAppearance: SidebarRowAppearance(isSelectedFill: selected))
        case .group(let group):
            HStack(spacing: PbRadius.Metrics.rowItemSpacing) {
                GroupRow(group: group.group, conversations: group.conversations, sidebarAppearance: SidebarRowAppearance(isSelectedFill: selected))
                if group.conversations.count > 1 {
                    Button { actions.toggle(group.id) } label: {
                        SidebarGroupDisclosure(isExpanded: group.isExpanded, reduceMotion: reduceMotion)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Expand or collapse \(group.name)")
                    .accessibilityValue(group.isExpanded ? "Expanded" : "Collapsed")
                }
            }
        case .workflow(let row):
            TaskRow(model: row, onToggleExpansion: row.hasChildren ? { actions.toggle("workflow:\(row.id)") } : nil,
                    sidebarAppearance: SidebarRowAppearance(isSelectedFill: selected))
                .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(selected ? Color.selectedRow : Color.clear))
        case .workflowShortcut(let row, _):
            TaskRow(model: row, sidebarAppearance: SidebarRowAppearance(isSelectedFill: selected))
                .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(selected ? Color.selectedRow : Color.clear))
        }
    }

    private func historyControl(_ source: String, state: HistoryLoadingState) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
            if state.catalogState.status == .blocked {
                Text(state.catalogState.reason ?? "History indexing is blocked. Resolve the reported record issue, then retry.")
                    .font(.pb(.caption))
.foregroundStyle(Color.warningFG)
            } else if state.authorityIncomplete {
                Text("History is blocked by a large legacy record. Inspect a known task directly to restore access.")
                    .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
            } else if state.historyIncomplete {
                Text("Some large legacy records need direct inspection; history ordering is incomplete.")
                    .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
            }
            if state.isLoading {
                LoadingLabel("Loading \(source.lowercased())…")
            } else if let error = state.error {
                Text(error.message).font(.pb(.caption)).foregroundStyle(Color.failedRed)
                Button("Retry \(source.lowercased())") { load(source) }
            } else if state.authorityIncomplete || state.catalogState.status == .blocked {
                Button("Retry \(source.lowercased())") { load(source) }
            } else if state.bootstrapPending {
                Text("Preparing \(source.lowercased()) history…").font(.pb(.caption))
                Button("Retry \(source.lowercased())") { load(source) }
            } else if state.hasMore {
                Button("Load older \(source.lowercased())") { load(source) }
            }
        }.frame(minHeight: max(PbRadius.Metrics.sidebarHistoryMinimumHeight, entry.minimumHeight), alignment: .leading)
    }

    private func load(_ source: String) {
        if source == "Tasks" { actions.loadTasks() } else { actions.loadWorkflows() }
    }
}

#if DEBUG
private struct SidebarNativeRowPreview: View {
    @Environment(\.self) private var environment
    var selected = false

    var body: some View {
        SidebarNativeRow(entry: .init(id: "preview", content: .workflowDefinition("Preview workflow")),
                         actions: SidebarNativeActions(), selected: selected, animate: false,
                         environment: environment, increasedProminence: false, occupiedHeight: { _ in })
            .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(selected ? Color.selectedRow : Color.clear))
    }
}

#Preview("Native sidebar row - light") {
    SidebarNativeRowPreview().preferredColorScheme(.light)
}

#Preview("Native sidebar row - dark") {
    SidebarNativeRowPreview().preferredColorScheme(.dark)
}

#Preview("Native sidebar selected row - light") {
    SidebarNativeRowPreview(selected: true).preferredColorScheme(.light)
}

#Preview("Native sidebar selected row - dark") {
    SidebarNativeRowPreview(selected: true).preferredColorScheme(.dark)
}
#endif
