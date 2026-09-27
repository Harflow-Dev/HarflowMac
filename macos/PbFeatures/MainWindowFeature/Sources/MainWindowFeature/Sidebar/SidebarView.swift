//
//  SidebarView.swift
//  MainWindowFeature
//
//  Ported from the app target's `SidebarView.swift`. Behaviour is unchanged: search is trimmed,
//  lowercased and case-insensitive over title/ID/repo; the backend filter composes with lineage
//  retention; section order, the empty state, the list-error display, the connection indicator and
//  row metadata/clock/age stay as they are. Group members appear only under Parallel runs.
//  `SettingsLink` stays.
//

import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - SidebarViewModel

/// View model protocol for the Sidebar screen.
@MainActor
protocol SidebarViewModel: ViewModel {
    
    var runningRows: [TaskRowModel] { get }
    var parallelGroups: [ParallelGroup] { get }
    var recentRows: [TaskRowModel] { get }
    var listErrorMessage: String? { get }
    var isEmptyState: Bool { get }
    var isConnected: Bool { get }
    var connectionLine: String { get }
    var availableBackends: [String] { get }
    var selectedBackend: String { get }
    var searchQuery: String { get }
    var selection: MonitorDestination? { get }
    /// The install/update banner, or `nil` when nothing needs surfacing — shown in place of the
    /// red error section (settled plan, section 5).
    var installBannerModel: InstallBanner.Model? { get }

    func didAppear()
    func didDisappear()
    func didChangeSearchQuery(_ text: String)
    func didSelectBackendFilter(_ backend: String)
    func didSelect(_ destination: MonitorDestination?)
    func didTapNewSession()
    func didTapInstallBannerPrimary()
    func didTapInstallBannerSecondary()
    func didTapInstallBannerDismiss()

    // MARK: Collapsible tree (settled plan, Monitor piece 4)

    func didToggleExpansion(taskID: String)
    /// ← collapses the selected row (or moves to its parent); → expands it — see `SidebarVM`.
    func didPressMoveCommand(_ direction: MoveCommandDirection)
}

// MARK: - SidebarView

struct SidebarView<VM: SidebarViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body
    
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Button {
                    viewModel.didTapNewSession()
                } label: {
                    Label("New session", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                TextField("Search tasks", text: Binding(get: { viewModel.searchQuery }, set: { viewModel.didChangeSearchQuery($0) }))
                    .textFieldStyle(.roundedBorder)
                Picker("Backend", selection: Binding(get: { viewModel.selectedBackend }, set: { viewModel.didSelectBackendFilter($0) })) {
                    Text("All").tag("all")
                    ForEach(viewModel.availableBackends, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(10)
            
            List(selection: Binding(get: { viewModel.selection }, set: { viewModel.didSelect($0) })) {
                if let bannerModel = viewModel.installBannerModel {
                    Section {
                        InstallBanner(
                            model: bannerModel,
                            onPrimary: { viewModel.didTapInstallBannerPrimary() },
                            onSecondary: { viewModel.didTapInstallBannerSecondary() },
                            onDismiss: { viewModel.didTapInstallBannerDismiss() }
                        )
                    }
                } else if let error = viewModel.listErrorMessage {
                    Section {
                        Text(error).font(.pb(.secondary)).foregroundStyle(Color.failedRed).textSelection(.enabled)
                    }
                }
                if !viewModel.runningRows.isEmpty {
                    Section { rows(viewModel.runningRows) } header: { SectionLabel(text: "Running \(rootCount(viewModel.runningRows))") }
                }
                if !viewModel.parallelGroups.isEmpty {
                    Section {
                        ForEach(viewModel.parallelGroups) { group in
                            GroupRow(group: group).tag(MonitorDestination.group(group.name))
                        }
                    } header: { SectionLabel(text: "Parallel runs \(viewModel.parallelGroups.count)") }
                }
                if !viewModel.recentRows.isEmpty {
                    Section { rows(viewModel.recentRows) } header: { SectionLabel(text: "Recent") }
                }
                if viewModel.isEmptyState {
                    Text("No tasks yet. Tasks started through polybridge appear here.")
                        .font(.pb(.body))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            .onMoveCommand { viewModel.didPressMoveCommand($0) }

            Divider()
            HStack {
                Circle().fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed).frame(width: 7, height: 7)
                Text(viewModel.connectionLine).font(.pb(.secondary)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
            }
            .padding(10)
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
    
    // MARK: - Private Views
    
    @ViewBuilder
    private func rows(_ rows: [TaskRowModel]) -> some View {
        ForEach(rows) { row in
            TaskRow(model: row, onToggleExpansion: row.hasChildren ? { viewModel.didToggleExpansion(taskID: row.id) } : nil)
                .tag(MonitorDestination.task(row.id))
        }
    }
    
    /// The old header count was the number of root trees, not the flattened row count.
    private func rootCount(_ rows: [TaskRowModel]) -> Int {
        rows.filter { $0.indent == 0 }.count
    }
}

#if DEBUG
#Preview {
    SidebarView(SidebarViewModelMock())
        .frame(width: 280, height: 600)
}

#Preview("install banner") {
    SidebarView(SidebarViewModelMock(installBannerModel: .init(
        title: "polybridge isn't installed",
        detail: "polybridge-ctl wasn't found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.",
        primaryTitle: "Install polybridge"
    )))
    .frame(width: 280, height: 600)
}

/// A three-level tree, expanded — Monitor piece 4.
#Preview("Tree - expanded") {
    SidebarView(SidebarViewModelMock(runningRows: [], recentRows: threeLevelTreeRows(collapsed: false)))
        .frame(width: 280, height: 600)
}

/// The same tree with the root collapsed: descendants hidden, meta line shows the subtree summary.
#Preview("Tree - collapsed") {
    SidebarView(SidebarViewModelMock(runningRows: [], recentRows: threeLevelTreeRows(collapsed: true)))
        .frame(width: 280, height: 600)
}

private func threeLevelTreeRows(collapsed: Bool) -> [TaskRowModel] {
    let root = TaskRowModel(
        id: "root", backend: "claude", title: "Ship the release", statusLabel: "Done", statusColor: .doneGreen, ageText: "1h",
        indent: 0, metaText: collapsed ? "~/repo · 3 sub-tasks, 1 running" : "~/repo · 3 sub-tasks", isRunning: false, startedAt: nil,
        hasChildren: true, isExpanded: !collapsed, guides: []
    )
    guard !collapsed else { return [root] }
    return [
        root,
        TaskRowModel(
            id: "childA", backend: "codex", title: "Draft the changelog", statusLabel: "Running", statusColor: .runningFG, ageText: "",
            indent: 1, metaText: "~/repo · 1 sub-task", isRunning: true, startedAt: .now.addingTimeInterval(-30),
            hasChildren: true, isExpanded: true, guides: [.branch]
        ),
        TaskRowModel(
            id: "grandchild", backend: "vibe", title: "Proofread", statusLabel: "Done", statusColor: .doneGreen, ageText: "2m",
            indent: 2, metaText: "~/repo", isRunning: false, startedAt: nil, hasChildren: false, isExpanded: true, guides: [.continuation, .last]
        ),
        TaskRowModel(
            id: "childB", backend: "opencode", title: "Tag the build", statusLabel: "Done", statusColor: .doneGreen, ageText: "5m",
            indent: 1, metaText: "~/repo", isRunning: false, startedAt: nil, hasChildren: false, isExpanded: true, guides: [.last]
        )
    ]
}
#endif
