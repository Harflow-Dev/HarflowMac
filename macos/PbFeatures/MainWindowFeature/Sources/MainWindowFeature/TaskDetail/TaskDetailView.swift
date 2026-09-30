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

/// The detail pane's tabs. Raw events are not a tab: they open as a sheet from the "…" menu.
enum TaskTab: String, CaseIterable, Identifiable {
    case activity = "Activity", summary = "Summary", prompt = "Prompt"
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
    /// Copies the current run's task id, recording the outcome like "Copy resume command" does.
    func didTapCopyTaskID()
    /// What the loading skeleton can already show — the conversation's title and repo name — when
    /// the listing knows the task; `nil` before that. Read synchronously, so it needs no subscription.
    var loadingHeader: TaskLoadingHeader? { get }
    /// Copies the task's repository path (the header's folder menu).
    func didTapCopyRepoPath()
    @discardableResult func submitMessage(_ text: String) -> Bool
}

// MARK: - TaskDetailView

struct TaskDetailView<VM: TaskDetailViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    @State private var isRawEventsPresented = false
    @AppStorage("monitor.inspectorVisible") private var isInspectorVisible = false
    @Environment(\.openURL) private var openURL
    
    // MARK: - Init
    
    init(_ viewModel: VM) {
        _viewModel = State(initialValue: viewModel)
    }
    
    // MARK: - View Body

    /// Monitor piece 12, Design point 2: `DeferredContent` shows `loadingSkeleton` on the first
    /// frame so picking a task changes the page instantly instead of freezing while the real
    /// detail's SwiftUI layout builds. Lives INSIDE the coordinator's per-conversation `.id(...)`
    /// (applied at `buildTaskDetailView(id:)`'s call site, wrapping this whole view) so a new
    /// selection gets a fresh `DeferredContentState` and starts on the placeholder again, while
    /// re-renders of the SAME selection never flash it a second time. `didAppear()`/`didDisappear()`
    /// stay on `realContent`, not the placeholder, so leases start once the real screen actually
    /// mounts — one committed frame after the selection, not on the very first frame.
    var body: some View {
        DeferredContent {
            loadingSkeleton
        } content: {
            realContent
                .onAppear { viewModel.didAppear() }
                .onDisappear { viewModel.didDisappear() }
        }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    @ViewBuilder
    private var realContent: some View {
        if let task = viewModel.task {
            withToolbar(task: task) {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        if hasHeaderContent { header(task) }
                        tabPicker
                        column
                    }
                    .background(Color.windowBG)
                    if isInspectorVisible {
                        HStack(spacing: 0) {
                            Divider()
                            InspectorView(model: viewModel.inspectorModel)
                                .frame(width: 280)
                        }
                        .transition(.move(edge: .trailing))
                    }
                }
                // Keyed on the value, not a withAnimation around the tap: the flag is @AppStorage, whose
                // change can land outside the tap's transaction and would then not animate.
                .animation(.easeInOut(duration: 0.25), value: isInspectorVisible)
                .opensFileLinks(repoPath: task.repoPath)
                .sheet(isPresented: $isRawEventsPresented) {
                    RawEventsSheetView(events: viewModel.rawEvents, path: viewModel.rawEventsPath) { isRawEventsPresented = false }
                }
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

    /// Shown while the task isn't known yet, and for the deferred first frame: the skeleton that
    /// mirrors the loaded screen (see `TaskLoadingSkeleton`). Never shown once `hasListed` is true —
    /// then either the task exists or it genuinely is not in polybridge's records.
    private var loadingSkeleton: some View {
        TaskLoadingSkeleton(header: viewModel.loadingHeader)
    }

    // MARK: Header

    /// Whatever the toolbar row can't carry: breadcrumbs, the outcome line, banners and the
    /// notice count. Empty (and so taking no space) for most tasks.
    private var hasHeaderContent: Bool {
        !viewModel.ancestorCrumbs.isEmpty || viewModel.outcomeMessage != nil || viewModel.takenOverBannerText != nil
            || viewModel.spawnedByBannerText != nil || !(viewModel.inspectorModel?.notices.isEmpty ?? true)
    }

    @ViewBuilder
    private func header(_ task: TaskInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !viewModel.ancestorCrumbs.isEmpty { breadcrumbs }
            if let message = viewModel.outcomeMessage {
                Text(message).font(.pb(.secondary)).foregroundStyle(OutcomeColor.of(message)).textSelection(.enabled)
            }
            if let text = viewModel.takenOverBannerText {
                Banner(icon: "person.fill", title: "Taken over", text: text)
            }
            if let text = viewModel.spawnedByBannerText {
                Banner(icon: "arrow.turn.down.right", title: "Sub-task started by another agent", text: text)
            }
            if let noticeText = NoticeSummary.text(count: viewModel.inspectorModel?.notices.count ?? 0) {
                Button {
                    isInspectorVisible = true
                } label: {
                    Label(noticeText, systemImage: "exclamationmark.triangle")
                        .font(.pb(.secondary))
                        .foregroundStyle(Color.warningFG)
                }
                .buttonStyle(.borderless)
                .help("Show the notices in the inspector")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    /// Attaches the toolbar layout the running OS supports; the glass-free one needs macOS 26 APIs.
    @ViewBuilder
    private func withToolbar(task: TaskInfo, @ViewBuilder content: () -> some View) -> some View {
        if #available(macOS 26.0, *) {
            content().toolbar { glassFreeToolbarContent(task) }
        } else {
            content().toolbar { toolbarContent(task) }
        }
    }

    /// The design's toolbar row: title and repo leading; status and actions trailing.
    @ToolbarContentBuilder
    private func toolbarContent(_ task: TaskInfo) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) { titleBlock(task) }
        ToolbarItem(placement: .primaryAction) { statusAndActions(task) }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(viewModel.ancestorCrumbs) { crumb in
                Button(crumb.title) { viewModel.didTapTask(crumb.id) }
                    .buttonStyle(.link)
                    .lineLimit(1)
                Text("›").foregroundStyle(Color.secondaryText)
            }
            Text(viewModel.title).foregroundStyle(Color.secondaryText).lineLimit(1)
        }
        .font(.pb(.secondary))
    }

    @ViewBuilder
    private func titleBlock(_ task: TaskInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(viewModel.title).font(.pb(.headline, weight: .semibold)).lineLimit(1).truncationMode(.tail).help(viewModel.title)
            HStack(spacing: 6) {
                repoMenu(task)
                if let turnsText = viewModel.turnsText { Text("· \(turnsText)") }
            }
            .font(.pb(.secondary))
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
        }
        // Capped so a long title truncates in the toolbar row instead of pushing the actions off it.
        .frame(maxWidth: 440, alignment: .leading)
    }

    /// The repository's name; clicking it offers to show the folder in Finder or copy its path.
    /// The path is the task's own recorded working directory, not agent text, so it goes to the
    /// system as a directory URL (Finder); toolbar items don't inherit the content's link rules.
    private func repoMenu(_ task: TaskInfo) -> some View {
        Menu {
            Button("Open in Finder") { openURL(URL(fileURLWithPath: task.repoPath, isDirectory: true)) }
            Button("Copy path") { viewModel.didTapCopyRepoPath() }
        } label: {
            Text(Format.repoName(task.repoPath))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(task.repoPath)
        .accessibilityLabel("Repository \(Format.repoName(task.repoPath))")
    }

    @ViewBuilder
    private func statusAndActions(_ task: TaskInfo) -> some View {
        HStack(spacing: 10) {
            statusLabel(task)
            takeoverButton
            moreMenu
            inspectorToggle
        }
        .fixedSize()
    }

    /// macOS 26 draws each toolbar item in a glass capsule, which turned the title and the whole
    /// action row into pills. Here the title, status and primary button sit on the bare toolbar, a
    /// flexible spacer pushes the actions to the trailing edge, and only "…" and the inspector
    /// toggle share one native glass group.
    @available(macOS 26.0, *)
    @ToolbarContentBuilder
    private func glassFreeToolbarContent(_ task: TaskInfo) -> some ToolbarContent {
        ToolbarItem(placement: .navigation) { titleBlock(task) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) { statusLabel(task) }
            .sharedBackgroundVisibility(.hidden)
        // The design's quiet buttons, each on the bare toolbar (no glass capsules): the primary
        // action and the inspector toggle draw their own QuietButtonStyle background, the "…" menu
        // is a plain icon.
        ToolbarItem(placement: .primaryAction) { takeoverButton }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            Menu {
                moreMenuItems
            } label: {
                Label("More actions", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("More actions")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { inspectorToggle }
            .sharedBackgroundVisibility(.hidden)
    }

    private var inspectorToggleText: String {
        isInspectorVisible ? "Hide inspector" : "Show inspector"
    }

    private func statusLabel(_ task: TaskInfo) -> some View {
        HStack(spacing: 8) {
            TaskStatusLabel(task: task).fixedSize()
            if viewModel.isBusy { ProgressView().controlSize(.small) }
        }
    }

    private var takeoverButton: some View {
        Button(viewModel.takeoverButtonLabel) { viewModel.didTapTakeover() }
            .buttonStyle(QuietButtonStyle())
            .disabled(!viewModel.canTakeover)
            .help(viewModel.takeoverHelp)
    }

    private var inspectorToggle: some View {
        Button {
            isInspectorVisible.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .buttonStyle(QuietButtonStyle(isSelected: isInspectorVisible))
        .help(inspectorToggleText)
        .accessibilityLabel(inspectorToggleText)
    }

    @ViewBuilder
    private var moreMenuItems: some View {
        if viewModel.canCancel {
            Button("Cancel", role: .destructive) { viewModel.didTapCancel() }.disabled(viewModel.isBusy)
        }
        if viewModel.resumeCommand != nil {
            Button("Copy resume command") { viewModel.didTapCopyResumeCommand() }
        }
        if let parentID = viewModel.openParentTaskID {
            Button("Open parent") { viewModel.didTapTask(parentID) }
        }
        Divider()
        Button("Raw events") { isRawEventsPresented = true }
    }

    private var moreMenu: some View {
        Menu {
            moreMenuItems
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    // MARK: Tabs and content

    private var tabPicker: some View {
        SlidingSegmentedControl(
            options: viewModel.tabs.map { ($0, $0.rawValue) },
            selection: Binding(get: { viewModel.tab }, set: { viewModel.didSelectTab($0) })
        )
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    /// Content over the composer. Each tab centres its own content with `readingColumn()` inside its
    /// scroll view (settled plan D13), so scrollbars sit at the pane's edge.
    private var column: some View {
        VStack(spacing: 0) {
            content
            MessageBoxView(model: viewModel.messageBoxModel) { text in viewModel.submitMessage(text) }
                .readingColumn()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.tab {
        case .activity:
            TimelinePaneView(model: viewModel.timelineModel)
        case .summary:
            SummaryPaneView(model: viewModel.summaryModel)
        case .prompt:
            ScrollView {
                Text(viewModel.promptText)
                    .font(.pb(.reading))
                    .lineSpacing(6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(24)
                    .readingColumn()
            }
        }
    }
}

// MARK: - NoticeSummary

/// The header's one-line pointer to the inspector's Notices section.
enum NoticeSummary {
    static func text(count: Int) -> String? {
        count > 0 ? "\(count) notice\(count == 1 ? "" : "s")" : nil
    }
}

#if DEBUG
@MainActor
private func previewDetail(_ mock: TaskDetailViewModelMock = TaskDetailViewModelMock()) -> some View {
    TaskDetailView(mock).frame(width: 1000, height: 620)
}

#Preview("Running - light") {
    previewDetail().preferredColorScheme(.light)
}

#Preview("Running - dark") {
    previewDetail().preferredColorScheme(.dark)
}

#Preview("Finished - light") {
    previewDetail(.finished()).preferredColorScheme(.light)
}

#Preview("Finished - dark") {
    previewDetail(.finished()).preferredColorScheme(.dark)
}
#endif
