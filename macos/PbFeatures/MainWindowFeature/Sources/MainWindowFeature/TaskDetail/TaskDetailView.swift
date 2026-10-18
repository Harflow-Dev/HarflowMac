//
//  TaskDetailView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TaskDetailView.swift`/`TaskDetailContent`/`MessageBox`. The
//  redesign (§6.2) restyles the header (title 18 semibold, agent/repo/turns/access meta line),
//  left-aligns the segmented tabs and keeps every action, route and guard unchanged. `.id(taskID)`
//  (F4-35) is applied by the caller (`MainWindowCoordinator.buildTaskDetailView`),
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
    var polybridgeApprovalBackend: String? { get }
    func didTapAllowPolybridgeTools()
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
    var artifactMembers: [ArtifactMemberModel] { get }
    func didLoadArtifacts(taskID: String)
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
    private let isEmbedded: Bool
    private let onToolbarEvaluation: (() -> Void)?
    @State private var embeddedInspectorVisible = false
    @State private var isRawEventsPresented = false
    @AppStorage("monitor.inspectorVisible") private var isInspectorVisible = false
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pbReduceMotionOverride) private var reduceMotionOverride
    
    // MARK: - Init
    
    init(_ viewModel: VM, isEmbedded: Bool = false, onToolbarEvaluation: (() -> Void)? = nil) {
        self.onToolbarEvaluation = onToolbarEvaluation
        self.isEmbedded = isEmbedded
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
                HStack(spacing: PbRadius.Metrics.zero) {
                    VStack(spacing: PbRadius.Metrics.zero) {
                        if let backend = viewModel.polybridgeApprovalBackend {
                            HStack(spacing: PbRadius.Metrics.spacing12) {
                                Text("\(backend.capitalized) needs approval to update this canvas.")
                                    .font(.pb(.secondary))
.foregroundStyle(Color.warningFG)
                                Spacer(minLength: PbRadius.Metrics.zero)
                                Button("Always allow Polybridge tools") { viewModel.didTapAllowPolybridgeTools() }
                                    .buttonStyle(QuietButtonStyle())
.disabled(viewModel.isBusy)
                            }
.padding(.horizontal, PbRadius.Metrics.spacing16)
.padding(.vertical, PbRadius.Metrics.spacing8)
                        }
                        if task.raw["caller_approvals"]?.boolValue == true || (task.raw["approval_summary"]?["pending_count"]?.intValue ?? 0) > 0 {
                            CallerApprovalPanel(taskID: viewModel.taskID, polls: task.status == .running)
                        }
                        header(task)
                        tabPicker
                        column
                    }
                    .frame(minWidth: PbRadius.Metrics.zero, maxWidth: .infinity, minHeight: PbRadius.Metrics.zero, maxHeight: .infinity)
                    .background(Color.windowBG)
                    if showsInspector {
                        HStack(spacing: PbRadius.Metrics.zero) {
                            Divider()
                            InspectorView(model: viewModel.inspectorModel)
                                .frame(width: PbRadius.Metrics.taskInspectorWidth)
                        }
                        .transition(.move(edge: .trailing))
                    }
                }
                // Keyed on the value, not a withAnimation around the tap: the flag is @AppStorage, whose
                // change can land outside the tap's transaction and would then not animate. Reduce
                // Motion drops the slide (§8); the pane still appears and disappears without motion.
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: showsInspector)
                .opensFileLinks(repoPath: task.repoPath)
                .sheet(isPresented: $isRawEventsPresented) {
                    RawEventsSheetView(events: viewModel.rawEvents, path: viewModel.rawEventsPath) { isRawEventsPresented = false }
                }
            }
        } else if viewModel.hasListed {
            VStack(spacing: PbRadius.Metrics.spacing8) {
                Text("Task \(viewModel.taskID)").font(.pb(.headline, weight: .bold))
                Text("This task is not in polybridge's records (it may have been removed by retention).")
                    .foregroundStyle(Color.secondaryText)
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
        TaskLoadingSkeleton(header: viewModel.loadingHeader, isEmbedded: isEmbedded)
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ task: TaskInfo) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing12) {
            if !viewModel.ancestorCrumbs.isEmpty { breadcrumbs }
            titleBlock(task)
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
                    setInspectorVisible(true)
                } label: {
                    Label(noticeText, systemImage: "exclamationmark.triangle")
                        .font(.pb(.secondary))
                        .monospacedDigit()
                        .foregroundStyle(Color.warningFG)
                }
                .buttonStyle(.borderless)
                .help("Show the notices in the inspector")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isEmbedded ? PbRadius.Metrics.spacing16 : PbRadius.Metrics.spacing24)
        .padding(.top, PbRadius.Metrics.spacing12)
    }

    /// Attaches the toolbar layout the running OS supports; the glass-free one needs macOS 26 APIs.
    @ViewBuilder
    private func withToolbar(task: TaskInfo, @ViewBuilder content: () -> some View) -> some View {
        if isEmbedded {
            VStack(spacing: PbRadius.Metrics.zero) {
                HStack(spacing: PbRadius.Metrics.spacing12) {
                    Spacer(minLength: PbRadius.Metrics.zero)
                    statusAndActions(task)
                }
.padding(.horizontal, PbRadius.Metrics.spacing16)
.padding(.vertical, PbRadius.Metrics.spacing10)
                Divider()
                content().frame(minWidth: PbRadius.Metrics.zero, maxWidth: .infinity, minHeight: PbRadius.Metrics.zero, maxHeight: .infinity)
            }
        } else {
            content().background {
                TaskDetailToolbar(
                    snapshot: TaskDetailToolbarSnapshot(viewModel, task: task, showsInspector: showsInspector),
                    actions: TaskDetailToolbarActions(
                        takeover: viewModel.didTapTakeover, cancel: viewModel.didTapCancel,
                        copyResumeCommand: viewModel.didTapCopyResumeCommand, openTask: viewModel.didTapTask,
                        showRawEvents: { isRawEventsPresented = true },
                        toggleInspector: { setInspectorVisible(!showsInspector) }
                    ),
                    onEvaluation: onToolbarEvaluation
                ).equatable()
            }
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: PbRadius.Metrics.spacing4) {
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

    /// The redesign's title block (§6.2): the page title at `.title` semibold in primary text, over
    /// a meta line of the agent label · repository menu · conversation turns · access — every value
    /// the header already carried, now all in one line.
    @ViewBuilder
    private func titleBlock(_ task: TaskInfo) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            Text(viewModel.title)
                .font(.pb(.title, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(viewModel.title)
            HStack(spacing: PbRadius.Metrics.spacing6) {
                BackendLabel(backend: task.backend)
                repoMenu(task)
                if let turnsText = viewModel.turnsText { Text("· \(turnsText)").monospacedDigit().fixedSize() }
                if let freedom = task.freedom {
                    Text("· \(AccessLabel.text(freedom: freedom))").lineLimit(1)
                }
            }
            .font(.pb(.secondary))
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
        }
        .frame(minWidth: PbRadius.Metrics.zero, maxWidth: .infinity, alignment: .leading)
    }

    /// The repository's name; clicking it offers to show the folder in Finder or copy its path.
    /// The path is the task's own recorded working directory, not agent text, so it goes to the
    /// system as a directory URL (Finder).
    private func repoMenu(_ task: TaskInfo) -> some View {
        Menu {
            Button("Open in Finder") { openURL(URL(fileURLWithPath: task.repoPath, isDirectory: true)) }
            Button("Copy path") { viewModel.didTapCopyRepoPath() }
        } label: {
            Text(Format.repoName(task.repoPath)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help(task.repoPath)
        .accessibilityLabel("Repository \(Format.repoName(task.repoPath))")
    }

    @ViewBuilder
    private func statusAndActions(_ task: TaskInfo) -> some View {
        HStack(spacing: PbRadius.Metrics.spacing10) {
            statusLabel(task)
            takeoverButton
            moreMenu
            inspectorToggle
        }
        .fixedSize()
    }

    /// Reduce Motion for the inspector transition: the presentation-only override wins over the
    /// system setting (`PbMotion.reduceMotion`), the same resolution shared components use.
    private var reduceMotion: Bool {
        PbMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    private var showsInspector: Bool { isEmbedded ? embeddedInspectorVisible : isInspectorVisible }

    private func setInspectorVisible(_ visible: Bool) {
        if isEmbedded { embeddedInspectorVisible = visible } else { isInspectorVisible = visible }
    }

    private var inspectorToggleText: String {
        showsInspector ? "Hide inspector" : "Show inspector"
    }

    private func statusLabel(_ task: TaskInfo) -> some View {
        HStack(spacing: PbRadius.Metrics.spacing8) {
            TaskStatusLabel(task: task).fixedSize()
            if viewModel.isBusy { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private var takeoverButton: some View {
        if !isEmbedded, WorkflowNodePresentation.allowsTerminal(viewModel.task) {
            TerminalActionButton(viewModel.takeoverButtonLabel, action: viewModel.didTapTakeover)
                .disabled(!viewModel.canTakeover)
                .help(viewModel.takeoverHelp)
        }
    }

    private var inspectorToggle: some View {
        Button {
            setInspectorVisible(!showsInspector)
        } label: {
            Image(systemName: "sidebar.right")
        }
        .buttonStyle(QuietButtonStyle(isSelected: showsInspector))
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
            Image(systemName: "ellipsis.circle").frame(width: PbRadius.Metrics.spacing24, height: PbRadius.Metrics.spacing24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    // MARK: Tabs and content

    /// The redesign places the segmented control left-aligned under the header (§6.2), inset to
    /// the content column's own padding; the tabs, binding and `didSelectTab` routing are today's.
    private var tabPicker: some View {
        SlidingSegmentedControl(
            options: viewModel.tabs.map { ($0, $0.rawValue) },
            selection: Binding(get: { viewModel.tab }, set: { viewModel.didSelectTab($0) })
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isEmbedded ? PbRadius.Metrics.spacing16 : PbRadius.Metrics.spacing24)
        .padding(.top, isEmbedded ? PbRadius.Metrics.spacing8 : PbRadius.Metrics.spacing16)
        .padding(.bottom, isEmbedded ? PbRadius.Metrics.spacing8 : PbRadius.Metrics.spacing16)
    }

    /// Content over the composer. Each tab centres its own content with `readingColumn()` inside its
    /// scroll view (settled plan D13), so scrollbars sit at the pane's edge.
    private var column: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
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
            SummaryPaneView(model: viewModel.summaryModel, artifactMembers: viewModel.artifactMembers,
                            loadArtifacts: { viewModel.didLoadArtifacts(taskID: $0) })
        case .prompt:
            ScrollView {
                Text(viewModel.promptText)
                    .font(.pb(.reading))
                    .lineSpacing(PbRadius.Metrics.spacing6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(PbRadius.Metrics.spacing24)
                    .readingColumn()
                    // The document probe (§6.2): inside the prompt pane's own document, so it
                    // can only ever target this scroll view.
                    .background(ScrollChrome())
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
    NavigationStack { TaskDetailView(mock) }
        .frame(width: PbRadius.Metrics.taskDetailPreviewWidth, height: PbRadius.Metrics.taskDetailPreviewHeight)
}

#Preview("Long title - narrow") {
    NavigationStack { TaskDetailView(TaskDetailViewModelMock.longTitle()) }
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Long title - narrow dark") {
    NavigationStack { TaskDetailView(TaskDetailViewModelMock.longTitle()) }
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Long title - wide") {
    previewDetail(.longTitle())
}

#Preview("Unbroken title - narrow") {
    NavigationStack { TaskDetailView(TaskDetailViewModelMock.longTitle(unbroken: true)) }
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Unbroken title - narrow dark") {
    NavigationStack { TaskDetailView(TaskDetailViewModelMock.longTitle(unbroken: true)) }
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Long title - embedded") {
    TaskDetailView(TaskDetailViewModelMock.longTitle(), isEmbedded: true)
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Long title - embedded dark") {
    TaskDetailView(TaskDetailViewModelMock.longTitle(), isEmbedded: true)
        .frame(width: PbRadius.Metrics.taskDetailNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.dark)
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
