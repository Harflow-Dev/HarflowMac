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
import PbUI
import SwiftUI

// MARK: - TaskTab

/// The detail pane's tabs.
enum TaskTab: String, CaseIterable, Identifiable {
    case timeline = "Timeline", summary = "Summary", prompt = "Prompt", raw = "Raw events"
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
    var isBusy: Bool { get }
    var outcomeMessage: String? { get }
    var takenOverBannerText: String? { get }
    var spawnedByBannerText: String? { get }
    var canTakeover: Bool { get }
    var takeoverButtonLabel: String { get }
    var takeoverHelp: String { get }
    var openParentTaskID: String? { get }
    var canCancel: Bool { get }
    /// A ready-to-paste `cd <repo> && <argv>` command (Monitor piece 3/3), read from the task's
    /// snapshot — `nil` hides the "Copy resume command" button entirely.
    var resumeCommand: String? { get }
    var copyResumeCommandHelp: String { get }
    /// "N turns" once this conversation has more than one member (Monitor piece 7) — `nil` for a
    /// plain, never-followed-up task.
    var turnsText: String? { get }

    var tab: TaskTab { get }
    var tabs: [TaskTab] { get }

    var timelineModel: TimelinePaneModel { get }
    var summaryModel: SummaryPaneModel { get }
    var promptText: String { get }
    var rawEvents: [TaskEvent] { get }
    var rawEventsPath: String { get }
    var inspectorModel: InspectorModel? { get }
    var messageBoxModel: MessageBoxModel { get }

    func didAppear()
    func didDisappear()
    func didSelectTab(_ tab: TaskTab)
    func didTapTask(_ taskID: String)
    func didTapTakeover()
    func didTapCancel()
    func didTapCopyResumeCommand()
    @discardableResult func submitMessage(_ text: String) -> Bool
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
                        MessageBoxView(model: viewModel.messageBoxModel) { text in viewModel.submitMessage(text) }
                    }
                    Divider()
                    InspectorView(model: viewModel.inspectorModel)
                        .frame(width: 280)
                }
            } else if viewModel.hasListed {
                VStack(spacing: 8) {
                    Text("Task \(viewModel.taskID)").font(.pb(.headline, weight: .bold))
                    Text("This task is not in polybridge's records (it may have been removed by retention).")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                loadingSkeleton
            }
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    /// Shown while the task isn't known yet (Plan review round 1, item 4) — replaces the old bare
    /// "Loading…" text. Never shown once `hasListed` is true: at that point either the task exists
    /// (the header/tabs render instead) or it genuinely is not in polybridge's records, and that
    /// message stays exactly as it was.
    private var loadingSkeleton: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                // `Color.primary.opacity(0.1)`, not `.neutralFill` — matches `SkeletonBlock`/
                // `SkeletonRows` (PbUI's own placeholders were invisible against `.neutralFill`).
                Circle().fill(Color.primary.opacity(0.1)).frame(width: 26, height: 26).shimmering()
                VStack(alignment: .leading, spacing: 6) {
                    SkeletonBlock(width: 220, height: 18)
                    SkeletonBlock(width: 140, height: 12)
                }
            }
            Divider()
            SkeletonRows(count: 5)
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                .font(.pb(.secondary))
            }
            // One row when everything fits; at a narrow width the title keeps its own row and the
            // status and actions move to a second row, rather than squeezing the title to nothing.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 10) {
                    titleBlock(task)
                    Spacer(minLength: 12)
                    statusAndActions(task)
                }
                VStack(alignment: .leading, spacing: 10) {
                    titleBlock(task)
                    HStack {
                        Spacer(minLength: 0)
                        statusAndActions(task)
                    }
                }
            }
            if let message = viewModel.outcomeMessage {
                Text(message).font(.pb(.secondary)).foregroundStyle(OutcomeColor.of(message)).textSelection(.enabled)
            }
            if let text = viewModel.takenOverBannerText {
                Banner(icon: "person.fill", title: "Taken over", text: text)
            }
            if let text = viewModel.spawnedByBannerText {
                Banner(icon: "arrow.turn.down.right", title: "Sub-task started by another agent", text: text)
            }
        }
        .padding(14)
    }
    
    @ViewBuilder
    private func titleBlock(_ task: TaskInfo) -> some View {
        HStack(alignment: .center, spacing: 10) {
                    BackendBadge(backend: task.backend, size: 26)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.title).font(.pb(.title, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                        HStack(spacing: 6) {
                            Text(task.backend).font(.pb(.secondary, weight: .medium))
                            if let effort = task.reasoningEffort { Text("effort \(effort)").font(.pb(.secondary)).foregroundStyle(.secondary) }
                            FreedomBadge(freedom: task.freedom)
                            if let turnsText = viewModel.turnsText { Text(turnsText).font(.pb(.secondary)).foregroundStyle(.secondary) }
                            Text(Format.repo(task.repoPath)).font(.pb(.secondary)).foregroundStyle(.secondary).lineLimit(1)
                            if task.depth > 0 { Text("depth \(task.depth)").font(.pb(.secondary)).foregroundStyle(.secondary) }
                            if let session = task.sessionID {
                                Text("session \(session.prefix(8))").font(.pb(.secondary, design: .monospaced)).foregroundStyle(.secondary)
                            }
                        }
                    }
        }
    }

    @ViewBuilder
    private func statusAndActions(_ task: TaskInfo) -> some View {
        HStack(spacing: 10) {
            StatusPill(task: task).fixedSize()
            actions
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 6) {
            if viewModel.isBusy { ProgressView().controlSize(.small) }
            Button(viewModel.takeoverButtonLabel) { viewModel.didTapTakeover() }
                .disabled(!viewModel.canTakeover)
                .help(viewModel.takeoverHelp)
            if viewModel.resumeCommand != nil {
                // Icon-only so the header still fits at the window's minimum width; the full name
                // stays as the tooltip and the accessibility label.
                Button { viewModel.didTapCopyResumeCommand() } label: {
                    Label("Copy resume command", systemImage: "doc.on.doc").labelStyle(.iconOnly)
                }
                .help(viewModel.copyResumeCommandHelp)
                .accessibilityLabel("Copy resume command")
            }
            if let parentID = viewModel.openParentTaskID {
                Button("Open parent") { viewModel.didTapTask(parentID) }
            }
            if viewModel.canCancel {
                Button("Cancel", role: .destructive) { viewModel.didTapCancel() }.disabled(viewModel.isBusy)
            }
        }
        // Buttons keep their full labels; the title and repo path truncate instead.
        .fixedSize()
    }
    
    // MARK: Tabs
    
    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(viewModel.tabs) { item in
                Button {
                    viewModel.didSelectTab(item)
                } label: {
                    Text(item.rawValue)
                    .font(.pb(.body, weight: viewModel.tab == item ? .semibold : .regular))
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
        case .summary:
            SummaryPaneView(model: viewModel.summaryModel)
        case .prompt:
            ScrollView {
                Text(viewModel.promptText)
                    .font(.pb(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
        case .raw:
            RawEventsPaneView(events: viewModel.rawEvents, path: viewModel.rawEventsPath)
        }
    }
}

#if DEBUG
#Preview {
    TaskDetailView(TaskDetailViewModelMock())
        .frame(width: 1000, height: 620)
}
#endif
