//
//  SidebarView.swift
//  MainWindowFeature
//
//  Header ("+" and a rounded search field), a fixed "All agents" filter menu row, the Running /
//  Today / Earlier list (whole trees and parallel groups, settled plan D10), and a connection
//  footer. Search is trimmed, lowercased and case-insensitive over title/ID/repo; the backend
//  filter composes with lineage retention. `SettingsLink` stays.
//

import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - SidebarViewModel

/// View model protocol for the Sidebar screen.
@MainActor
protocol SidebarViewModel: ViewModel {
    
    /// Running / Today / Earlier, in that order, empty buckets omitted (settled plan D10).
    var sections: [SidebarSection] { get }
    var listErrorMessage: String? { get }
    /// The list body's empty-state message, or `nil` when there's real content to show (Monitor
    /// piece 6's precedence rules — see `SidebarVM.computeEmptyStateMessage()`).
    var emptyStateMessage: String? { get }
    /// A shimmer placeholder instead of an empty list (Monitor piece 11, Plan review round 1 item
    /// 4): true only before the first listing arrives (`hasListed == false`) with no error and no
    /// install banner already occupying the space — see `SidebarVM.recompute()`.
    var showsLoadingSkeleton: Bool { get }
    var isConnected: Bool { get }
    var connectionLine: String { get }
    var backendTabs: [BackendTab] { get }
    var selectedBackend: String { get }
    var catalogUnavailableNote: String? { get }
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
            header
            filterRow
            list
            footer
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    // MARK: - Private Views

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.secondaryText)
                TextField("Search", text: Binding(get: { viewModel.searchQuery }, set: { viewModel.didChangeSearchQuery($0) }))
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: PbRadius.row).fill(Color.pillFill))
            Button {
                viewModel.didTapNewSession()
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help("New session")
            .accessibilityLabel("New session")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    /// The backend filter: always visible, even while the list below is empty.
    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                ForEach(viewModel.backendTabs) { tab in
                    Button {
                        viewModel.didSelectBackendFilter(tab.id)
                    } label: {
                        if tab.id == viewModel.selectedBackend {
                            Label(menuTitle(for: tab), systemImage: "checkmark")
                        } else {
                            Text(menuTitle(for: tab))
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(selectedTitle).font(.pb(.secondary, weight: .medium))
                    Image(systemName: "chevron.down").font(.pb(.caption, weight: .semibold))
                }
                .foregroundStyle(Color.secondaryText)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Backend filter")
            .accessibilityValue(selectedTitle)
            if let note = viewModel.catalogUnavailableNote {
                Text(note).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    private var selectedTitle: String {
        viewModel.selectedBackend == "all" ? "All agents" : BackendStyle.displayName(viewModel.selectedBackend)
    }

    private func menuTitle(for tab: BackendTab) -> String {
        if tab.id == "all" { return "All agents" }
        let name = BackendStyle.displayName(tab.id)
        return tab.isNotFound ? "\(name) (not found on PATH)" : name
    }

    private var list: some View {
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
            if viewModel.showsLoadingSkeleton {
                Section { SkeletonRows() }
            } else {
                ForEach(viewModel.sections) { section in
                    Section {
                        ForEach(section.items) { item in itemView(item) }
                    } header: {
                        SectionLabel(text: section.title)
                    }
                }
                if let message = viewModel.emptyStateMessage {
                    Text(message)
                        .font(.pb(.body))
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .listStyle(.sidebar)
        .onMoveCommand { viewModel.didPressMoveCommand($0) }
    }

    @ViewBuilder
    private func itemView(_ item: SidebarItem) -> some View {
        switch item {
        case .task(let row):
            TaskRow(model: row, onToggleExpansion: row.hasChildren ? { viewModel.didToggleExpansion(taskID: row.id) } : nil)
                .tag(MonitorDestination.task(row.id))
        case .group(let group):
            GroupRow(group: group).tag(MonitorDestination.group(group.name))
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Circle().fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed).frame(width: 7, height: 7)
                Text(viewModel.isConnected ? "Connected" : "Disconnected")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .help(viewModel.listErrorMessage ?? viewModel.connectionLine)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
}

#if DEBUG
#Preview("Default - light") {
    SidebarView(SidebarViewModelMock()).frame(width: 272, height: 600).preferredColorScheme(.light)
}

#Preview("Default - dark") {
    SidebarView(SidebarViewModelMock()).frame(width: 272, height: 600).preferredColorScheme(.dark)
}

#Preview("Install banner - light") {
    SidebarView(SidebarViewModelMock(installBannerModel: installBannerPreviewModel())).frame(width: 272, height: 600).preferredColorScheme(.light)
}

#Preview("Install banner - dark") {
    SidebarView(SidebarViewModelMock(installBannerModel: installBannerPreviewModel())).frame(width: 272, height: 600).preferredColorScheme(.dark)
}

#Preview("Loading - light") {
    SidebarView(SidebarViewModelMock(sections: [], showsLoadingSkeleton: true)).frame(width: 272, height: 600).preferredColorScheme(.light)
}

#Preview("Loading - dark") {
    SidebarView(SidebarViewModelMock(sections: [], showsLoadingSkeleton: true)).frame(width: 272, height: 600).preferredColorScheme(.dark)
}

#Preview("Empty, disconnected - light") {
    SidebarView(SidebarViewModelMock(
        sections: [], emptyStateMessage: "No claude tasks yet.", isConnected: false, selectedBackend: "claude"
    ))
    .frame(width: 272, height: 400)
    .preferredColorScheme(.light)
}

#Preview("Empty, disconnected - dark") {
    SidebarView(SidebarViewModelMock(
        sections: [], emptyStateMessage: "No claude tasks yet.", isConnected: false, selectedBackend: "claude"
    ))
    .frame(width: 272, height: 400)
    .preferredColorScheme(.dark)
}

/// A three-level tree, expanded — Monitor piece 4.
#Preview("Tree - expanded - light") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: false))]))
        .frame(width: 272, height: 600)
        .preferredColorScheme(.light)
}

#Preview("Tree - expanded - dark") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: false))]))
        .frame(width: 272, height: 600)
        .preferredColorScheme(.dark)
}

/// The same tree with the root collapsed: descendants hidden, meta line shows the subtree summary.
#Preview("Tree - collapsed - light") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: true))]))
        .frame(width: 272, height: 600)
        .preferredColorScheme(.light)
}

#Preview("Tree - collapsed - dark") {
    SidebarView(SidebarViewModelMock(sections: [SidebarSection(bucket: .earlier, items: threeLevelTreeRows(collapsed: true))]))
        .frame(width: 272, height: 600)
        .preferredColorScheme(.dark)
}

private func installBannerPreviewModel() -> InstallBanner.Model {
    InstallBanner.Model(
        title: "polybridge isn't installed",
        detail: "polybridge-ctl wasn't found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin.",
        primaryTitle: "Install polybridge"
    )
}

private func threeLevelTreeRows(collapsed: Bool) -> [SidebarItem] {
    let root = TaskRowModel(
        id: "root", backend: "claude", title: "Ship the release", status: .completed, repoName: "repo", ageText: "1h",
        indent: 0, subTaskSummary: collapsed ? "3 sub-tasks, 1 running" : "3 sub-tasks", startedAt: nil,
        hasChildren: true, isExpanded: !collapsed, guides: []
    )
    guard !collapsed else { return [.task(root)] }
    return [
        .task(root),
        .task(TaskRowModel(
            id: "childA", backend: "codex", title: "Draft the changelog", status: .running, repoName: "repo", ageText: "",
            indent: 1, subTaskSummary: "1 sub-task", startedAt: .now.addingTimeInterval(-30),
            hasChildren: true, isExpanded: true, guides: [.branch]
        )),
        .task(TaskRowModel(
            id: "grandchild", backend: "vibe", title: "Proofread", status: .completed, repoName: "repo", ageText: "2m",
            indent: 2, startedAt: nil, hasChildren: false, isExpanded: true, guides: [.continuation, .last]
        )),
        .task(TaskRowModel(
            id: "childB", backend: "opencode", title: "Tag the build", status: .completed, repoName: "repo", ageText: "5m",
            indent: 1, startedAt: nil, hasChildren: false, isExpanded: true, guides: [.last]
        ))
    ]
}
#endif
