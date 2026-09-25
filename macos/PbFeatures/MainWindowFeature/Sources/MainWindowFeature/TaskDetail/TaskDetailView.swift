//
//  TaskDetailView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TaskDetailView.swift`/`TaskDetailContent`/`MessageBox`. No
//  behaviour change: strings, sizes, fonts, colours and enable/disable rules stay exactly as they
//  were. `.id(taskID)` (F4-35) is applied by the caller (`MainWindowCoordinator.buildTaskDetailView`),
//  never inside this view's own body — see that method's header comment and the phase-4 brief's
//  binding Lesson.
//

import MonitorCore
import PbCommon
import PbRepository
import PbTerminal
import PbUI
import SwiftUI

// MARK: - TaskTab

/// The detail pane's tabs. The Terminal tab exists only while there is a session (F4-37) and is
/// inserted at index 2.
enum TaskTab: String, CaseIterable, Identifiable {
    case timeline = "Timeline", changes = "Changes", prompt = "Prompt", raw = "Raw events", terminal = "Terminal"
    var id: String { rawValue }
}

// MARK: - AncestorCrumb

/// One breadcrumb above a sub-task's title.
struct AncestorCrumb: Identifiable {
    let id: String
    let title: String
}

// MARK: - TaskDetailViewModel

/// View model protocol for the task detail screen.
@MainActor
protocol TaskDetailViewModel: ViewModel {
    
    var taskID: String { get }
    var task: TaskInfo? { get }
    var hasListed: Bool { get }
    
    var title: String { get }
    var ancestorCrumbs: [AncestorCrumb] { get }
    var isDrivenByUser: Bool { get }
    var isBusy: Bool { get }
    var outcomeMessage: String? { get }
    var takenOverBannerText: String? { get }
    var drivingBannerText: String? { get }
    var spawnedByBannerText: String? { get }
    var canTakeover: Bool { get }
    var takeoverButtonLabel: String { get }
    var takeoverHelp: String { get }
    var openParentTaskID: String? { get }
    var canCancel: Bool { get }
    
    var tab: TaskTab { get }
    var tabs: [TaskTab] { get }
    var changesFileCount: Int { get }
    /// The message box is hidden on the Terminal tab (`TaskDetailView.swift:116` pre-port).
    var showsMessageBox: Bool { get }
    
    var timelineModel: TimelinePaneModel { get }
    var changesModel: ChangesPaneModel { get }
    var promptText: String { get }
    var rawEvents: [TaskEvent] { get }
    var rawEventsPath: String { get }
    var inspectorModel: InspectorModel? { get }
    var messageBoxModel: MessageBoxModel { get }
    var terminalSession: TerminalSession? { get }
    
    func didAppear()
    func didDisappear()
    func didSelectTab(_ tab: TaskTab)
    func didTapTask(_ taskID: String)
    func didSelectTakeoverDestination(_ destination: TakeoverDestination)
    func didTapCancel()
    @discardableResult func submitMessage(_ text: String) -> Bool
    func didTapReloadChanges()
    func didTapEndSession()
    func didTapCloseSession()
    func previewFile(path: String) async -> FilePreviewResult
}

// MARK: - TaskDetailView

struct TaskDetailView<VM: TaskDetailViewModel>: View {
    
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
        Group {
            if let task = viewModel.task {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        header(task)
                        Divider()
                        tabBar
                        Divider()
                        content
                        if viewModel.showsMessageBox {
                            Divider()
                            MessageBoxView(model: viewModel.messageBoxModel) { text in viewModel.submitMessage(text) }
                        }
                    }
                    Divider()
                    InspectorView(model: viewModel.inspectorModel)
                        .frame(width: 280)
                }
            } else {
                VStack(spacing: 8) {
                    Text("Task \(viewModel.taskID)").font(.headline)
                    Text(viewModel.hasListed ? "This task is not in polybridge's records (it may have been removed by retention)." : "Loading…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
    
    // MARK: Header
    
    @ViewBuilder
    private func header(_ task: TaskInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !viewModel.ancestorCrumbs.isEmpty {
                HStack(spacing: 4) {
                    ForEach(viewModel.ancestorCrumbs) { crumb in
                        Button(crumb.title) { viewModel.didTapTask(crumb.id) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                        Text("›").foregroundStyle(.secondary)
                    }
                    Text(viewModel.title).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(size: 11))
            }
            HStack(alignment: .center, spacing: 10) {
                BackendBadge(backend: task.backend, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.title).font(.system(size: 16, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(task.backend).font(.system(size: 11, weight: .medium))
                        if let effort = task.reasoningEffort { Text("effort \(effort)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        FreedomBadge(freedom: task.freedom)
                        Text(Format.repo(task.repoPath)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        if task.depth > 0 { Text("depth \(task.depth)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        if let session = task.sessionID {
                            Text("session \(session.prefix(8))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                StatusPill(task: task, drivenByUser: viewModel.isDrivenByUser)
                actions
            }
            if let message = viewModel.outcomeMessage {
                Text(message).font(.system(size: 11)).foregroundStyle(OutcomeColor.of(message)).textSelection(.enabled)
            }
            if let text = viewModel.takenOverBannerText {
                Banner(icon: "person.fill", title: "Taken over", text: text)
            }
            if let text = viewModel.drivingBannerText {
                Banner(icon: "terminal", title: "You're driving", text: text, tint: Color(hex: 0x8A4B00))
            }
            if let text = viewModel.spawnedByBannerText {
                Banner(icon: "arrow.turn.down.right", title: "Sub-task started by another agent", text: text)
            }
        }
        .padding(14)
    }
    
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if viewModel.isBusy { ProgressView().controlSize(.small) }
            if !viewModel.isDrivenByUser {
                Menu {
                    Button("In this window") { viewModel.didSelectTakeoverDestination(.embedded) }
                    Button("In Terminal.app") { viewModel.didSelectTakeoverDestination(.terminalApp) }
                } label: {
                    Text(viewModel.takeoverButtonLabel)
                } primaryAction: {
                    viewModel.didSelectTakeoverDestination(.embedded)
                }
                .fixedSize()
                .disabled(!viewModel.canTakeover)
                .help(viewModel.takeoverHelp)
            }
            if let parentID = viewModel.openParentTaskID {
                Button("Open parent") { viewModel.didTapTask(parentID) }
            }
            if viewModel.canCancel {
                Button("Cancel", role: .destructive) { viewModel.didTapCancel() }.disabled(viewModel.isBusy)
            }
        }
    }
    
    // MARK: Tabs
    
    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(viewModel.tabs) { item in
                Button {
                    viewModel.didSelectTab(item)
                } label: {
                    HStack(spacing: 4) {
                        Text(item.rawValue)
                        if item == .changes, viewModel.changesFileCount > 0 {
                            Text("\(viewModel.changesFileCount)")
                                .font(.system(size: 10, weight: .semibold))
                                .padding(.horizontal, 5)
                                .background(Capsule().fill(Color.hairline))
                        }
                    }
                    .font(.system(size: 12, weight: viewModel.tab == item ? .semibold : .regular))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(viewModel.tab == item ? Color.selectedRow : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
    
    @ViewBuilder
    private var content: some View {
        switch viewModel.tab {
        case .timeline:
            TimelinePaneView(model: viewModel.timelineModel)
        case .changes:
            ChangesPaneView(model: viewModel.changesModel)
        case .prompt:
            ScrollView {
                Text(viewModel.promptText)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        case .raw:
            RawEventsPaneView(events: viewModel.rawEvents, path: viewModel.rawEventsPath)
        case .terminal:
            if let session = viewModel.terminalSession {
                TerminalPaneView(session: session, onEndSession: { viewModel.didTapEndSession() }, onClose: { viewModel.didTapCloseSession() })
            } else {
                Text("No terminal").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

#if DEBUG
#Preview {
    TaskDetailView(TaskDetailViewModelMock())
        .frame(width: 1000, height: 620)
}
#endif
