//
//  TaskDetailView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TaskDetailView.swift`/`TaskDetailContent`/`MessageBox`. The
//  redesign (§6.2) restyles the header (title 18 semibold, agent/repo/turns/access meta line)
//  and keeps every action, route and guard unchanged. `.id(taskID)`
//  (F4-35) is applied by the caller (`MainWindowCoordinator.buildTaskDetailView`),
//  never inside this view's own body — see that method's header comment and the phase-4 brief's
//  binding Lesson.
//

import HfCommon
import HfRepository
import HfUI
import MonitorCore
import SwiftUI

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
    var resourceContext: TaskResourceContext? { get }
    var resourceBlockersExpanded: Bool { get }
    func didToggleResourceBlockers()
    func didOpenResourceSlots()
    var hasListed: Bool { get }
    
    var title: String { get }
    var ancestorCrumbs: [AncestorCrumb] { get }
    var isBusy: Bool { get }
    var outcomeMessage: String? { get }
    var harflowApprovalBackend: String? { get }
    func didTapAllowHarflowTools()
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

    var callerApprovalController: CallerApprovalController? { get }
    var timelineModel: TimelinePaneModel { get }
    var artifactMembers: [ArtifactMemberModel] { get }
    func didLoadArtifacts(taskID: String)
    var summaryModel: SummaryPaneModel { get }
    /// Whether the Activity feed ends with the Summary entry, which the Events usage group then does not repeat.
    var summaryEntryShown: Bool { get }
    var promptText: String { get }
    var requestReadState: TaskRequestReadState { get }
    var observationFrames: [String: EventObservationFrame] { get }
    var orderedHistoryFrames: [EventObservationFrame] { get }
    var recoveredTranscript: RecoveredTranscriptFrame { get }
    var copyFeedback: String? { get }
    func didReadRequest(maxBytes: Int)
    func didCopyObservationText(_ text: String)
    func didRequestObservation(_ action: EventObservationAction, taskID: String)
    var rawEvents: [TaskEvent] { get }
    var inspectorModel: InspectorModel? { get }
    var messageBoxModel: MessageBoxModel { get }

    func didAppear()
    func didDisappear()
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
    @discardableResult func submitMessageNow(_ text: String) -> Bool
    func cancelQueuedMessage(_ messageID: String)
}

extension TaskDetailViewModel {
    var requestReadState: TaskRequestReadState { .notRequested }
    var observationFrames: [String: EventObservationFrame] { [:] }
    var orderedHistoryFrames: [EventObservationFrame] { [] }
    var recoveredTranscript: RecoveredTranscriptFrame { .init() }
    var copyFeedback: String? { nil }
    func didReadRequest(maxBytes _: Int) {}
    func didCopyObservationText(_: String) {}
    func didRequestObservation(_: EventObservationAction, taskID _: String) {}

    var resourceContext: TaskResourceContext? { nil }
    var resourceBlockersExpanded: Bool { false }
    func didToggleResourceBlockers() {}
    func didOpenResourceSlots() {}
    var callerApprovalController: CallerApprovalController? { nil }
}

// MARK: - TaskDetailView

struct TaskDetailView<VM: TaskDetailViewModel>: View {
    
    // MARK: - Environment
    
    @Environment(\.viewEvent) var viewEvent
    
    // MARK: - State
    
    @State var viewModel: VM
    @State private var activityState: ParallelColumnUIState
    @State var paneHolder: TaskPaneHolder
    let chrome: TaskDetailChrome
    let transcriptStyle: ActivityFeedStyle
    private let onToolbarEvaluation: (() -> Void)?
    @State var eventsExpanded = true
    @State var snapshotFactsExpanded = false
    @State var supervisionRequest = 0
    /// The header control a facts reveal started from, so Escape and a closed pane can return focus to it.
    @FocusState var originFocus: TaskPaneController.Origin?
    @AccessibilityFocusState var originAccessibilityFocus: TaskPaneController.Origin?
    @AccessibilityFocusState var groupAccessibilityFocus: TaskPaneStateStore.FactsGroup?
    @FocusState var focusedGroup: TaskPaneStateStore.FactsGroup?
    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride
    
    // MARK: - Init
    
    /// `chrome` selects the mount: `.standalone` draws the adaptive right pane and keeps its choices through
    /// `paneBinding` (a private store when none is given); `.group`, the default, and `.embedded` keep the
    /// always-mounted legacy pane.
    init(_ viewModel: VM, chrome: TaskDetailChrome = .group, paneBinding: TaskPaneBinding? = nil,
         activityState: ParallelColumnUIState? = nil, transcriptStyle: ActivityFeedStyle = .standard,
         onToolbarEvaluation: (() -> Void)? = nil) {
        self.transcriptStyle = transcriptStyle
        _activityState = State(initialValue: activityState ?? ParallelColumnUIState())
        self.onToolbarEvaluation = onToolbarEvaluation
        self.chrome = chrome
        let fallbackID = viewModel.taskID
        _paneHolder = State(initialValue: TaskPaneHolder {
            let binding = paneBinding ?? TaskPaneBinding(store: TaskPaneStateStore(), conversationID: fallbackID)
            return TaskPaneController(store: binding.store, conversationID: binding.conversationID)
        })
        _viewModel = State(initialValue: viewModel)
    }

    private var isEmbedded: Bool { chrome == .embedded }
    var isStandalone: Bool { chrome == .standalone }
    var pane: TaskPaneController { paneHolder.controller }
    
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
                if isStandalone {
                    standaloneLayout(task)
                } else {
                    legacyLayout(task)
                }
            }
        } else if viewModel.hasListed {
            VStack(spacing: HfRadius.Metrics.spacing8) {
                Text("Task \(viewModel.taskID)").font(.hf(.headline, weight: .bold))
                Text("This task is not in harflow's records (it may have been removed by retention).")
                    .foregroundStyle(Color.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(transcriptStyle.isTranscript ? TaskScreenStyle.Colors.pageBackground.color : Color.clear)
        } else {
            loadingSkeleton
        }
    }

    /// The transcript column: approval banner, header, resource card, activity and composer.
    func columnStack(_ task: TaskInfo) -> some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            if let backend = viewModel.harflowApprovalBackend {
                HStack(spacing: HfRadius.Metrics.spacing12) {
                    Text("\(backend.capitalized) needs approval to update this canvas.")
                        .font(.hf(.secondary))
                        .foregroundStyle(Color.warningFG)
                    Spacer(minLength: HfRadius.Metrics.zero)
                    Button("Always allow Harflow tools") { viewModel.didTapAllowHarflowTools() }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(viewModel.isBusy)
                }
                .padding(.horizontal, HfRadius.Metrics.spacing16)
                .padding(.vertical, HfRadius.Metrics.spacing8)
            }
            header(task)
            if let context = viewModel.resourceContext {
                TaskResourceContextView(context: context, blockersExpanded: viewModel.resourceBlockersExpanded,
                                        onToggleBlockers: viewModel.didToggleResourceBlockers,
                                        onOpenResourceSlots: viewModel.didOpenResourceSlots)
                    .padding(.horizontal, HfRadius.Metrics.spacing16)
                    .padding(.bottom, HfRadius.Metrics.spacing8)
            }
            column
        }
        .frame(minWidth: HfRadius.Metrics.zero, maxWidth: .infinity, minHeight: HfRadius.Metrics.zero, maxHeight: .infinity)
        .background(transcriptStyle.isTranscript ? TaskScreenStyle.Colors.pageBackground.color : Color.windowBG)
    }

    /// Group and embedded mounts: the column beside the always-mounted pane.
    private func legacyLayout(_ task: TaskInfo) -> some View {
        HStack(spacing: HfRadius.Metrics.zero) {
            columnStack(task)
            Divider()
            eventsPane
                .frame(width: isEmbedded ? 280 : 320)
        }
        // Keyed on the value, not a withAnimation around the tap: the flag is @AppStorage, whose
        // change can land outside the tap's transaction and would then not animate. Reduce
        // Motion drops the slide (§8); the pane still appears and disappears without motion.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: eventsExpanded)
        .onChange(of: eventsExpanded) { wasVisible, visible in
            if wasVisible, !visible, supervisionRequest > 0 { originFocus = .continuityDetails }
        }
        .opensFileLinks(repoPath: task.repoPath)
    }

    /// Shown while the task isn't known yet, and for the deferred first frame: the skeleton that
    /// mirrors the loaded screen (see `TaskLoadingSkeleton`). Never shown once `hasListed` is true —
    /// then either the task exists or it genuinely is not in harflow's records.
    private var loadingSkeleton: some View {
        TaskLoadingSkeleton(header: viewModel.loadingHeader, isEmbedded: isEmbedded, style: transcriptStyle)
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ task: TaskInfo) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            if !viewModel.ancestorCrumbs.isEmpty { breadcrumbs }
            titleBlock(task)
            if let message = viewModel.outcomeMessage {
                Text(message).font(.hf(.secondary)).foregroundStyle(OutcomeColor.of(message)).textSelection(.enabled)
            }
            if let text = viewModel.takenOverBannerText {
                Banner(icon: "person.fill", title: "Taken over", text: text)
            }
            if let text = viewModel.spawnedByBannerText {
                Banner(icon: "arrow.turn.down.right", title: "Sub-task started by another agent", text: text)
            }
            if NoticeSummary.text(count: viewModel.inspectorModel?.notices.count ?? 0) != nil
                || viewModel.inspectorModel?.showsContinuity == true {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                    if let noticeText = NoticeSummary.text(count: viewModel.inspectorModel?.notices.count ?? 0) {
                        Button {
                            revealNotices()
                        } label: {
                            HStack(alignment: .top, spacing: HfRadius.Metrics.spacing8) {
                                supplementalIcon("exclamationmark.triangle")
                                Text(noticeText).monospacedDigit()
                            }
                            .foregroundStyle(Color.warningFG)
                        }
                        .buttonStyle(.plain)
                        .modifier(StandaloneFocusable(isEnabled: isStandalone))
                        .focused($originFocus, equals: .notices)
                        .accessibilityFocused($originAccessibilityFocus, equals: .notices)
                        .help(isStandalone ? "Show the notices in the right pane" : "Show the notices in the inspector")
                    }
                    if viewModel.inspectorModel?.showsContinuity == true {
                        HStack(alignment: .top, spacing: HfRadius.Metrics.spacing8) {
                            supplementalIcon("arrow.clockwise")
                            Text("Server restarted · Task still running")
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: HfRadius.Metrics.spacing8)
                            Button("Details") { revealContinuityDetails() }
                            .buttonStyle(.plain)
                            .modifier(StandaloneFocusable(isEnabled: isStandalone))
                            .focused($originFocus, equals: .continuityDetails)
                            .accessibilityFocused($originAccessibilityFocus, equals: .continuityDetails)
                            .accessibilityLabel("Show supervision details")
                        }
                        .foregroundStyle(Color.secondaryText)
                    }
                }
                .font(.hf(.secondary))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, isEmbedded ? HfRadius.Metrics.spacing16 : HfRadius.Metrics.spacing24)
        .padding(.top, HfRadius.Metrics.spacing12)
        .padding(.bottom, HfRadius.Metrics.spacing12)
    }

    private func supplementalIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: HfRadius.Metrics.spacing16)
            .accessibilityHidden(true)
    }

    /// Attaches the toolbar layout the running OS supports; the glass-free one needs macOS 26 APIs.
    @ViewBuilder
    private func withToolbar(task: TaskInfo, @ViewBuilder content: () -> some View) -> some View {
        if isEmbedded {
            VStack(spacing: HfRadius.Metrics.zero) {
                HStack(spacing: HfRadius.Metrics.spacing12) {
                    Spacer(minLength: HfRadius.Metrics.zero)
                    statusAndActions(task)
                }
.padding(.horizontal, HfRadius.Metrics.spacing16)
.padding(.vertical, HfRadius.Metrics.spacing10)
                Divider()
                content().frame(minWidth: HfRadius.Metrics.zero, maxWidth: .infinity, minHeight: HfRadius.Metrics.zero, maxHeight: .infinity)
            }
        } else {
            content().background {
                TaskDetailToolbar(
                    snapshot: TaskDetailToolbarSnapshot(viewModel, task: task, showsInspector: isStandalone ? pane.isOpen : eventsExpanded,
                                                        isRightPane: isStandalone),
                    actions: TaskDetailToolbarActions(
                        takeover: viewModel.didTapTakeover, cancel: viewModel.didTapCancel,
                        copyResumeCommand: viewModel.didTapCopyResumeCommand, openTask: viewModel.didTapTask,
                        showRawEvents: showEvents,
                        toggleInspector: toggleInspector
                    ),
                    onEvaluation: onToolbarEvaluation
                ).equatable()
            }
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: HfRadius.Metrics.spacing4) {
            ForEach(viewModel.ancestorCrumbs) { crumb in
                Button(crumb.title) { viewModel.didTapTask(crumb.id) }
                    .buttonStyle(.link)
                    .lineLimit(1)
                Text("›").foregroundStyle(Color.secondaryText)
            }
            Text(viewModel.title).foregroundStyle(Color.secondaryText).lineLimit(1)
        }
        .font(.hf(.secondary))
    }

    /// The redesign's title block (§6.2): the page title at `.title` semibold in primary text, over
    /// a meta line of the agent label · repository menu · conversation turns · access — every value
    /// the header already carried, now all in one line.
    @ViewBuilder
    private func titleBlock(_ task: TaskInfo) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            Text(viewModel.title)
                .font(.hf(.title, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(viewModel.title)
            HStack(spacing: HfRadius.Metrics.spacing6) {
                BackendLabel(backend: task.backend)
                repoMenu(task)
                if let turnsText = viewModel.turnsText { Text("· \(turnsText)").monospacedDigit().fixedSize() }
                if let freedom = task.freedom {
                    Text("· \(AccessLabel.text(freedom: freedom))").lineLimit(1)
                }
            }
            .font(.hf(.secondary))
            .foregroundStyle(Color.secondaryText)
            .lineLimit(1)
        }
        .frame(minWidth: HfRadius.Metrics.zero, maxWidth: .infinity, alignment: .leading)
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
        HStack(spacing: HfRadius.Metrics.spacing10) {
            statusLabel(task)
            takeoverButton
            moreMenu
            inspectorToggle
        }
        .fixedSize()
    }

    /// Reduce Motion for the inspector transition: the presentation-only override wins over the
    /// system setting (`HfMotion.reduceMotion`), the same resolution shared components use.
    var reduceMotion: Bool {
        HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    func setInspectorVisible(_ visible: Bool) {
        eventsExpanded = visible
    }

    private var inspectorToggleText: String {
        eventsExpanded ? "Hide event details" : "Show event details"
    }

    private func statusLabel(_ task: TaskInfo) -> some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            TaskStatusLabel(task: task).fixedSize()
            if viewModel.isBusy { ProgressView().controlSize(.small) }
        }
    }

    @ViewBuilder
    private var takeoverButton: some View {
        if !isEmbedded {
            TerminalActionButton(viewModel.takeoverButtonLabel, action: viewModel.didTapTakeover)
                .disabled(!viewModel.canTakeover || !WorkflowNodePresentation.allowsTerminal(viewModel.task))
                .help(WorkflowNodePresentation.allowsTerminal(viewModel.task) ? viewModel.takeoverHelp
                      : "This managed or native task cannot be taken over. Open its owning workflow for supported controls.")
        }
    }

    private var inspectorToggle: some View {
        Button {
            eventsExpanded.toggle()
        } label: {
            Image(systemName: "sidebar.right")
        }
        .buttonStyle(QuietButtonStyle(isSelected: eventsExpanded))
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
        Button("Events") { eventsExpanded = true }
    }

    private var moreMenu: some View {
        Menu {
            moreMenuItems
        } label: {
            Image(systemName: "ellipsis.circle").frame(width: HfRadius.Metrics.spacing24, height: HfRadius.Metrics.spacing24).contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
        .accessibilityLabel("More actions")
    }

    /// Content over the composer. The feed centres its own content with `readingColumn()` inside its
    /// scroll view (settled plan D13), so scrollbars sit at the pane's edge.
    private var column: some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            content
            MessageBoxView(model: viewModel.messageBoxModel, onSubmitNow: viewModel.submitMessageNow,
                           style: transcriptStyle.isTranscript ? .transcript : .standard) { text in viewModel.submitMessage(text) }
                .readingColumn()
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            StoredRequestView(state: viewModel.requestReadState, read: viewModel.didReadRequest, copy: viewModel.didCopyObservationText)
                .padding(16)
            ForEach(viewModel.orderedHistoryFrames, id: \.taskID) { frame in
                ObservationHistoryView(frame: frame) { viewModel.didRequestObservation($0, taskID: frame.taskID) }
                    .padding(.horizontal, 16)
.padding(.bottom, 8)
            }
            if let feedback = viewModel.copyFeedback { Text(feedback).font(.hf(.caption)).textSelection(.enabled) }
            TimelinePaneView(model: viewModel.timelineModel, state: activityState, approvalController: viewModel.callerApprovalController,
                             isCancelDisabled: viewModel.isBusy, style: transcriptStyle)
        }
    }

    private var eventsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Events").font(.hf(.secondary, weight: .semibold)).padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if eventsExpanded {
                        PublicEventsView(frame: viewModel.task.flatMap { viewModel.observationFrames[$0.taskID] },
                                         recovered: viewModel.recoveredTranscript, copy: viewModel.didCopyObservationText)
                    }
                    DisclosureGroup("Task snapshot facts and actions", isExpanded: $snapshotFactsExpanded) {
                        TaskSnapshotFactsView(model: viewModel.inspectorModel, supervisionRequest: supervisionRequest)
                            .frame(height: 360)
                    }
                    DisclosureGroup("Reported result, usage and artifacts") {
                        SummaryPaneView(model: viewModel.summaryModel, showsHeroAndResult: true, artifactMembers: viewModel.artifactMembers,
                                        loadArtifacts: { viewModel.didLoadArtifacts(taskID: $0) })
                            .frame(height: 360)
                    }
                }.padding(16)
            }
        }.background(Color.inspectorFill)
    }

}

// MARK: - NoticeSummary

/// The header's one-line pointer to the inspector's Notices section.
enum NoticeSummary {
    static func text(count: Int) -> String? {
        count > 0 ? "\(count) notice\(count == 1 ? "" : "s")" : nil
    }
}

// MARK: - StandaloneFocusable

/// Makes a control programmatically focusable on the standalone mount only. Elsewhere it is the identity, so the
/// group and embedded mounts keep the controls' default focus behaviour exactly.
private struct StandaloneFocusable: ViewModifier {
    let isEnabled: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled { content.focusable() } else { content }
    }
}
