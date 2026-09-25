//
//  SidebarView.swift
//  MainWindowFeature
//
//  Ported from the app target's `SidebarView.swift`. Behaviour is unchanged: search is trimmed,
//  lowercased and case-insensitive over title/ID/repo; the backend filter composes with lineage
//  retention; section order, the empty state, the list-error display, the connection indicator and
//  row metadata/clock/age stay as they are. Group members appear only under Parallel runs.
//  Interactive sessions are listed (ended ones excluded), with the terminal icon shown for a live
//  session. `SettingsLink` stays.
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
    var interactiveRows: [InteractiveSessionRowModel] { get }
    var recentRows: [TaskRowModel] { get }
    var listErrorMessage: String? { get }
    var isEmptyState: Bool { get }
    var isConnected: Bool { get }
    var connectionLine: String { get }
    var availableBackends: [String] { get }
    var selectedBackend: String { get }
    var searchQuery: String { get }
    var selection: MonitorDestination? { get }
    
    func didAppear()
    func didDisappear()
    func didChangeSearchQuery(_ text: String)
    func didSelectBackendFilter(_ backend: String)
    func didSelect(_ destination: MonitorDestination?)
    func didTapNewSession()
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
                if let error = viewModel.listErrorMessage {
                    Section {
                        Text(error).font(.system(size: 11)).foregroundStyle(Color.failedRed).textSelection(.enabled)
                    }
                }
                if !viewModel.runningRows.isEmpty {
                    Section { rows(viewModel.runningRows) } header: { SectionLabel(text: "Running \(rootCount(viewModel.runningRows))") }
                }
                if !viewModel.parallelGroups.isEmpty {
                    Section {
                        ForEach(viewModel.parallelGroups) { group in
                            GroupRow(group: group).tag(MonitorDestination.group(group.name) as MonitorDestination?)
                        }
                    } header: { SectionLabel(text: "Parallel runs \(viewModel.parallelGroups.count)") }
                }
                if !viewModel.interactiveRows.isEmpty {
                    Section {
                        ForEach(viewModel.interactiveRows) { row in
                            InteractiveSessionRow(model: row)
                                .tag(MonitorDestination.interactive(row.id) as MonitorDestination?)
                        }
                    } header: { SectionLabel(text: "Interactive") }
                }
                if !viewModel.recentRows.isEmpty {
                    Section { rows(viewModel.recentRows) } header: { SectionLabel(text: "Recent") }
                }
                if viewModel.isEmptyState {
                    Text("No tasks yet. Tasks started through polybridge appear here.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)
            
            Divider()
            HStack {
                Circle().fill(viewModel.isConnected ? Color.doneGreen : Color.failedRed).frame(width: 7, height: 7)
                Text(viewModel.connectionLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
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
            TaskRow(model: row).tag(MonitorDestination.task(row.id) as MonitorDestination?)
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
#endif
