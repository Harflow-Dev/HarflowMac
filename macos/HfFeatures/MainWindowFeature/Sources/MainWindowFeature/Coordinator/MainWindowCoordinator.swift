//
//  MainWindowCoordinator.swift
//  MainWindowFeature
//

import AppKit
import Combine
import Foundation
import HfCommon
import HfRepository
import HfUI
import HfUtilities
import MonitorCore
import SwiftEnvironment
import SwiftUI

// `GlobalValues.monitorVisibility`/`GlobalValues.scheduling` resolve here at VM-build time —
// after `ApplicationModules.initialize()` has registered the real values.

// MARK: - PasteboardWriting

/// Seam over `NSPasteboard` (Monitor piece 3/3's "Copy resume command") so a test can verify a
/// copy without touching the real system clipboard — the same reason `chooseDirectory()` below
/// keeps `NSOpenPanel` out of the VM layer, just for the pasteboard instead of a panel.
@MainActor
public protocol PasteboardWriting {
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: PasteboardWriting {}

// MARK: - MainWindowCoordinator

/// The main window's coordinator: builds the Sidebar and New Session screens and owns the
/// navigation state above. `handle(path:)` applies its own destinations (`task`/`group`/
/// `newSession`) and bubbles anything else (`openWindow`, or a destination outside
/// `MonitorDestination` entirely) to its parent.
@MainActor
@Observable
public final class MainWindowCoordinator: MainWindowNavigationCoordinator {
    let continuityHistory: any TaskContinuityHistory = TaskContinuityHistoryStore()
    /// Side-pane choices per conversation, kept here because the task view's own state is reset on selection.
    let paneState = TaskPaneStateStore()
    /// Carries the standalone task's top bar content to the shell's principal toolbar item.
    public let topBar = TaskTopBarHolder()
    /// Unsent messages of standalone tasks, kept across navigation. Not observable: see `TaskDraftStore`.
    let draftStore = TaskDraftStore()
    @ObservationIgnored var draftPartitionCache = TaskDraftPartition.empty

    // MARK: - Public Properties

    public let parent: any Coordinator
    public var path: [PathDestination] { [] }

    public var selection: MonitorDestination? {
        didSet {
            guard selection != oldValue else { return }
            resourceSlotsVM?.readingState.setSelected(selection == .resourceSlots)
            if selection != resourceSlotsReturnDestination {
                resourceSlotsReturnDestination = nil
                if selection != .resourceSlots || resourceSlotsVM?.readingState.hasAuthorizedFocusReturn != true {
                    resourceSlotsVM?.readingState.clearFocusReturn()
                }
            }
            selectionSubject.send(selection)
            isNewSessionPresentedSubject.send(selection == .newSession)
            discardStopConfirmationIfConversationChanged()
            if selection != .pendingLaunches { endPendingStop(reason: .discard, closeSheet: true) }
            topBar.setShownSubject(shownTopBarSubject())
        }
    }

    public var presentedSheet: MainWindowSheet? {
        didSet {
            // Leaving the pending-launch Stop sheet by any route other than its own buttons discards the request.
            if presentedSheet != .stopPendingLaunch { endPendingStop(reason: .discard) }
            if presentedSheet == .stopPendingLaunch, pendingStopRequest == nil { presentedSheet = nil; return }
            if presentedSheet != .stopTask { stopConfirmation = nil }
            if presentedSheet == .stopTask, stopConfirmation == nil { presentedSheet = nil; return }
            if presentedSheet == .newSession {
                presentedSheet = nil
                openNewSession()
                return
            }
            if presentedSheet != .workflowRunner { initialWorkflowRunnerName = nil }
            if presentedSheet != nil, !runtimeIsReady { presentedSheet = nil; return }
        }
    }

    public var isNewSessionPresented: Bool {
        get { selection == .newSession }
        set {
            if newValue {
                openNewSession()
            } else if selection == .newSession {
                selection = nil
            }
        }
    }

    public var isWorkflowRunnerPresented: Bool {
        get { presentedSheet == .workflowRunner }
        set {
            if newValue {
                presentedSheet = .workflowRunner
            } else if presentedSheet == .workflowRunner {
                presentedSheet = nil
            }
        }
    }

    public func presentWorkflowRunner() { openWorkflowRunner(name: nil) }

    var stopConfirmation: TaskStopConfirmation?
    /// The pending-launch Stop request whose sheet is shown; see `MainWindowCoordinator+PendingStop`.
    var pendingStopRequest: PendingLaunchStopRequest?
    /// Requests whose sheet was closed and whose native dismissal callback has not arrived yet.
    var awaitingStopDismissal: [PendingLaunchStopRequest] = []
    var initialWorkflowRunnerName: String?

    func openWorkflowRunner(name: String?) {
        guard runtimeIsReady else { return }
        initialWorkflowRunnerName = name
        isWorkflowRunnerPresented = true
    }

    public func buildStartScreenView() -> AnyView {
        StartScreenView(sharedStartScreenVM()).eraseToAnyView()
    }

    public private(set) var runtimeIsReady = true
    public private(set) var runtimeSetupState: RuntimeSetupState = .ready
    public private(set) var hasLoadedWork = false
    public private(set) var loadingWorkError: String?
    @ObservationIgnored private var runtimeSubscription: AnyCancellable?
    @ObservationIgnored private var listingSubscription: AnyCancellable?
    @ObservationIgnored private var listingChangeSubscription: AnyCancellable?

    // MARK: - Private Properties

    @ObservationIgnored private let selectionSubject = CurrentValueSubject<MonitorDestination?, Never>(nil)
    @ObservationIgnored private let isNewSessionPresentedSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored let workflowRunPolling = WorkflowRunPolling()
    @ObservationIgnored private var sidebarVM: SidebarVM?
    @ObservationIgnored private var startScreenVM: StartScreenVM?
    @ObservationIgnored private var newSessionVM: NewSessionVM?
    @ObservationIgnored private var statisticsVM: StatisticsVM?
    @ObservationIgnored private var resourceSlotsVM: ResourceSlotsVM?
    @ObservationIgnored private var pendingLaunchesVM: PendingLaunchesVM?
    private var resourceSlotsReturnDestination: MonitorDestination?
    @ObservationIgnored private var needsYouVM: NeedsYouVM?
    @ObservationIgnored private let pasteboard: any PasteboardWriting
    @ObservationIgnored private let installRepository: any InstallRepository
    /// The latest unconsumed navigation-triggered reveal (settled plan, Design point 5's
    /// "coordinator owns the pending reveal") — set on every navigation request for a task, so it
    /// survives even while the sidebar is unsubscribed (window closed).
    @ObservationIgnored private(set) var pendingReveal: PendingReveal?
    @ObservationIgnored private let revealSubject = PassthroughSubject<PendingReveal, Never>()
    /// Read to normalise a task id to its conversation (`normalisedConversationID(for:)`, the task view's `.id()` key
    /// and the top bar's shown conversation) and by the group presenter — never to drive any other behaviour.
    @ObservationIgnored @GlobalEnvironment(\.taskListRepository) var taskListRepository

    // MARK: - Init

    public init(
        parent: any Coordinator,
        pasteboard: any PasteboardWriting = NSPasteboard.general,
        installRepository: (any InstallRepository)? = nil,
        taskListRepository: (any TaskListRepository)? = nil
    ) {
        self.parent = parent
        self.pasteboard = pasteboard
        self.installRepository = installRepository ?? GlobalValues.installRepository
        if let taskListRepository { self.taskListRepository = taskListRepository }
        let listing = self.taskListRepository
        self.listingChangeSubscription = listing.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.listingChanged() }
        self.hasLoadedWork = listing.hasListed
        self.loadingWorkError = listing.listError?.message
        self.listingSubscription = listing.hasListedPublisher()
.combineLatest(listing.listErrorPublisher())
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasListed, error in
                guard let self else { return }
                if hasLoadedWork != hasListed { self.hasLoadedWork = hasListed }
                let message = error?.message
                if loadingWorkError != message { self.loadingWorkError = message }
            }
        let install = self.installRepository
        self.runtimeIsReady = install.setupState.isReady
        self.runtimeSetupState = install.setupState
        self.runtimeSubscription = install.setupStatePublisher().receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            if runtimeIsReady != state.isReady { self.runtimeIsReady = state.isReady }
            if runtimeSetupState != state { self.runtimeSetupState = state }
            if !state.isReady { self.presentedSheet = nil }
            resourceSlotsVM?.runtimeChanged()
        }
    }

    // MARK: - Public Methods

    public func handle(path: any PathDestination) {
        guard let destination = path as? MonitorDestination else {
            parent.handle(path: path)
            return
        }
        if !runtimeIsReady {
            switch destination {
            case .newSession, .newWorkflow, .workflow, .workflowLibrary: return
            default: break
            }
        }
        switch destination {
        case .task(let id):
            selection = destination
            // Covers the URL/notification/menu-bar reveal triggers — `MenuBarCoordinator.select(_:)`
            // and the app target's URL/notification handling both bubble here (see this package's
            // `AGENTS.md`).
            requestReveal(taskID: id)
        case .group, .workflow, .workflowLibrary, .newWorkflow, .workflowRun, .statistics, .resourceSlots, .pendingLaunches, .needsYou: selection = destination
        case .newSession: openNewSession()
        case .openWindow: parent.handle(path: destination)
        }
    }

    public func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never> { selectionSubject.removeDuplicates().eraseToAnyPublisher() }
    public func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never> { isNewSessionPresentedSubject.removeDuplicates().eraseToAnyPublisher()
    }

    // MARK: - Pending reveal (settled plan, Design point 5)

    /// Records a fresh reveal request for `taskID` — a new `requestID` every time, repeats included,
    /// since `selection`'s own `didSet` drops a repeated assignment and would otherwise silently
    /// swallow navigating twice to the same already-selected, hidden task.
    private func requestReveal(taskID: String) {
        let reveal = PendingReveal(taskID: taskID, requestID: UUID())
        pendingReveal = reveal
        revealSubject.send(reveal)
    }

    public func buildStatisticsView() -> AnyView {
        let vm = statisticsVM ?? StatisticsVM(useCase: StatisticsViewRepository())
        statisticsVM = vm
        return StatisticsView(vm).eraseToAnyView()
    }

    public func buildResourceSlotsView() -> AnyView {
        let vm = resourceSlotsVM ?? ResourceSlotsVM(useCase: ResourceSlotsViewRepository(), routing: self)
        resourceSlotsVM = vm
        return ResourceSlotsView(vm).eraseToAnyView()
    }

    public func buildPendingLaunchesView() -> AnyView {
        let vm = pendingLaunchesVM ?? PendingLaunchesVM(useCase: PendingLaunchesViewRepository(), routing: self)
        pendingLaunchesVM = vm
        return PendingLaunchesView(vm).eraseToAnyView()
    }

    public var canReturnToResourceSlots: Bool {
        resourceSlotsReturnDestination != nil && selection == resourceSlotsReturnDestination
    }

    public func returnToResourceSlots() {
        guard canReturnToResourceSlots else { return }
        resourceSlotsVM?.readingState.authorizeFocusReturn()
        selection = .resourceSlots
    }

    public func buildNeedsYouView(itemID: String?) -> AnyView {
        let vm = needsYouVM ?? NeedsYouVM(useCase: NeedsYouViewRepository(), routing: self)
        needsYouVM = vm
        return NeedsYouView(vm, itemID: itemID).eraseToAnyView()
    }

    public func buildSidebarView() -> AnyView {
        SidebarView(sharedSidebarVM(), managesLifecycle: false).eraseToAnyView()
    }

    public func buildNavigationRail(expand: @escaping @MainActor () -> Void) -> AnyView {
        SidebarNavigationRail(sharedSidebarVM(), expand: expand).eraseToAnyView()
    }

    public func startShellObservation() { sharedSidebarVM().didAppear() }
    public func stopShellObservation() { sidebarVM?.didDisappear() }
    public func performRuntimeSetup() {
        guard !runtimeSetupState.isReady, !runtimeSetupState.isBusy else { return }
        let install = installRepository
        Task { await install.install() }
    }

    public func buildConnectionStatusView() -> AnyView {
        ConnectionStatusView(ConnectionStatusVM(useCase: SidebarViewRepository())).eraseToAnyView()
    }
    
    /// The window owns one composer, so navigation and appearance never replay or reset a submission.
    public func buildNewSessionView() -> AnyView {
        NewSessionView(sharedNewSessionVM()).eraseToAnyView()
    }

    func sharedNewSessionVM() -> NewSessionVM {
        if let newSessionVM { return newSessionVM }
        let vm = NewSessionVM(useCase: NewSessionViewRepository(), routing: self)
        newSessionVM = vm
        return vm
    }
    
    @ObservationIgnored private var parallelPositions: [String: ParallelViewportPosition] = [:]

    func parallelPosition(for key: String) -> ParallelViewportPosition {
        if let position = parallelPositions[key] { return position }
        let position = ParallelViewportPosition()
        parallelPositions[key] = position
        return position
    }

    /// A selected group's stable presenter observes membership for its entire visible lifetime.
    public func buildParallelView(name: String) -> AnyView {
        let vm = GroupPresentationVM(
            groupName: name,
            useCase: GroupPresentationViewRepository(taskListRepository: taskListRepository),
            routing: self,
            makeDetail: { [self] id in
                TaskDetailVM(taskID: id, useCase: TaskDetailViewRepository(), routing: self, continuityHistory: continuityHistory,
                             chrome: .group, scheduler: GlobalValues.scheduling)
            },
            makeParallel: { [self] in
                ParallelVM(groupName: name, useCase: ParallelViewRepository(), routing: self, horizontalPosition: parallelPosition(for: "group:" + name),
                           publishesTopBar: true)
            }
        )
        return GroupPresentationView(vm).id(name).eraseToAnyView()
    }

    /// The first task of the group's only agent conversation, or `nil` when the group has none or
    /// several (then it is a real parallel run). Membership is read when the view is built.
    nonisolated static func soleConversationID(inGroup name: String, tasks: [TaskInfo]) -> String? {
        guard let group = Lineage.sections(tasks).parallel.first(where: { $0.name == name }) else { return nil }
        let sessions = WorkflowOrchestratorConversation.conversations(group.conversations.flatMap(\.members))
        guard sessions.count == 1 else { return nil }
        return sessions[0].first.taskID
    }

    /// A fresh VM every call, keyed by `id` exactly like `buildParallelView(name:)` above: `.id()`
    /// wraps the whole `TaskDetailView(vm)` value here, at the call site — never inside
    /// `TaskDetailView.body`, which owns no `@State` of its own (its `.id()` need is satisfied by
    /// this call site resetting the VM itself, not by an inner `.id()` the way the old
    /// `TaskDetailView`'s `EventScope` needed one). See `buildParallelView(name:)`'s header comment
    /// and the phase-4 brief's binding Lesson for why the placement matters.
    ///
    /// The `.id()` key is `id` normalised to its conversation's first member (Monitor piece 7,
    /// Review round 1 item 4), never the raw `id` this was called with: `id` may be any member (a
    /// URL/notification/breadcrumb can carry a non-first one), and two different members of the
    /// SAME conversation must keep the identical VM instance rather than rebuilding on every such navigation. `TaskDetailVM` itself is still built
    /// with the raw `id`; it resolves the whole conversation from whichever member it is given.
    ///
    /// Leaving the task for another destination unmounts this view, so the composer's unsent text does not live in
    /// it: it lives in `draftStore`, which this method writes nothing observable to, and survives the unmount.
    public func buildTaskDetailView(id: String) -> AnyView {
        let useCase = TaskDetailViewRepository()
        let (conversationID, members) = conversationKeyAndMembers(for: id)
        let vm = TaskDetailVM(taskID: id, useCase: useCase, routing: self, continuityHistory: continuityHistory, chrome: .standalone,
                              scheduler: GlobalValues.scheduling, topBarConversationID: conversationID)
        let paneBinding = TaskPaneBinding(store: paneState, conversationID: conversationID)
        let draft = draftMount(key: conversationID, members: members) { [weak vm] in vm?.currentTaskID ?? id }
        let view = TaskDetailView(vm, chrome: .standalone, paneBinding: paneBinding, transcriptStyle: .transcript, draft: draft)
        return view.id(conversationID).eraseToAnyView()
    }
    
    /// `id` normalised to its conversation's first member: the key of the task view's `.id(...)`, its pane state and
    /// its top bar writer. Shared by `buildTaskDetailView(id:)` and the top bar's shown conversation, so the two
    /// never disagree about which conversation a task id belongs to.
    func normalisedConversationID(for id: String) -> String {
        conversationKeyAndMembers(for: id).key
    }

    /// The conversation the current selection shows as a standalone task, `nil` for every other selection.
    func shownTaskConversation() -> String? {
        if case .task(let id) = selection { normalisedConversationID(for: id) } else { nil }
    }

    /// The subject the top bar shows content for: the selected task's conversation or the selected group, `nil` otherwise.
    func shownTopBarSubject() -> TopBarSubject? {
        switch selection {
        case .task(let id): .task(normalisedConversationID(for: id))
        case .group(let name): .group(name)
        default: nil
        }
    }

    /// The listing changed: refresh the shown conversation, unless a mounted task view is still showing under the old
    /// id. A retention shift then keeps the title until a selection change or rebuild re-keys the view.
    private func listingChanged() {
        reconcileDrafts()
        guard topBar.activeTag == nil else { return }
        topBar.setShownSubject(shownTopBarSubject())
    }

    // MARK: - ViewCoordinator
    
    /// The main window's whole `NavigationSplitView`, per this dispatch's own instruction — not just
    /// the sidebar any more.
    public func start() -> AnyView {
        MainWindowNavigationView(self).eraseToAnyView()
    }
    
    // MARK: - Private Methods
    
    /// Retains the refresh throttle when selection changes rebuild the unselected detail pane.
    func sharedStartScreenVM() -> StartScreenVM {
        if let startScreenVM { return startScreenVM }
        let vm = StartScreenVM(useCase: StartScreenViewRepository(), routing: self)
        startScreenVM = vm
        return vm
    }

    private func sharedSidebarVM() -> SidebarVM {
        if let sidebarVM { return sidebarVM }
        let useCase = SidebarViewRepository()
        let newVM = SidebarVM(
            useCase: useCase,
            routing: self,
            workflowUseCase: useCase,
            visibility: GlobalValues.monitorVisibility,
            scheduler: GlobalValues.scheduling
        )
        newVM.invocationDetails = { [weak self] id in self?.workflowRunPolling.cached(id: id) }
        sidebarVM = newVM
        return newVM
    }
}

// MARK: - SidebarRouting

extension MainWindowCoordinator: SidebarRouting {
    /// The sidebar's own click — deliberately does **not** call `requestReveal(taskID:)`: Design
    /// point 5 excludes the sidebar's own selection from the reveal triggers (a click can only
    /// select a row that is already visible).
    public func select(_ destination: MonitorDestination?) {
        if !runtimeIsReady {
            switch destination {
            case .newSession, .newWorkflow, .workflow, .workflowLibrary: return
            default: break
            }
        }
        selection = destination
    }

    public func openNewSession() {
        guard runtimeIsReady else { return }
        presentedSheet = nil
        sharedNewSessionVM().prepareForNewTask()
        selection = .newSession
    }

    public func retryLoadingWork() {
        let listing = taskListRepository
        Task { _ = await listing.refreshAndWait() }
    }

    func revealPublisher() -> AnyPublisher<PendingReveal, Never> { revealSubject.eraseToAnyPublisher() }

    /// A no-op once `requestID` has already been superseded by a later reveal (or already consumed).
    func consumeReveal(requestID: UUID) {
        guard pendingReveal?.requestID == requestID else { return }
        pendingReveal = nil
    }
}

// MARK: - NewSessionRouting

extension MainWindowCoordinator: NewSessionRouting {
    /// `NSOpenPanel` is AppKit, which is allowed here (the coordinator, in the feature layer) —
    /// just not in `NewSessionVM`, which only calls `routing.chooseDirectory()` and awaits the
    /// result. Modal, exactly like the old `NewSessionSheet.choose()`.
    public func chooseDirectory() async -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
    
    public func didStart(taskID: String) {
        selection = .task(taskID)
    }

    public func reviewRecent() {
        // Only navigate to a task actually observed through the public listing.
        if let task = taskListRepository.tasks.max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) {
            selectTask(task.taskID)
        }
        sharedSidebarVM().didTapLoadMoreTasks()
    }

    public func dismiss() {
        isNewSessionPresented = false
    }
}

// MARK: - ParallelRouting

extension MainWindowCoordinator: ParallelRouting {
    /// Shared with `TaskDetailRouting.selectTask(_:)` below (one implementation satisfies both
    /// conformances) — covers the Parallel "open task" click, ancestor-breadcrumb taps, and "Open
    /// parent", all of Design point 5's non-sidebar reveal triggers besides URL/notification/menu
    /// bar (handled in `handle(path:)` above).
    public func selectTask(_ taskID: String) {
        let logicalID = WorkflowOrchestratorConversation.members(containing: taskID, in: taskListRepository.tasks)?.first?.taskID ?? taskID
        selection = .task(logicalID)
        requestReveal(taskID: logicalID)
    }
}

// MARK: - PendingLaunchesRouting

extension MainWindowCoordinator: PendingLaunchesRouting {
    /// Opens the ordinary task screen for an ID the owner admitted through a fresh status read.
    func openRecordedTask(_ taskID: String) { selectTask(taskID) }

    func presentPendingLaunchStop(_ request: PendingLaunchStopRequest) { presentPendingStop(request) }
    func dismissPendingLaunchStop() { endPendingStop(reason: .discard, closeSheet: true) }
}

// MARK: - TaskDetailRouting

extension MainWindowCoordinator: TaskDetailRouting {
    func publishTopBar(_ content: TaskTopBarContent, tag: TaskTopBarHolder.Tag) { topBar.publish(content, tag: tag) }
    func publishTopBar(_ content: GroupTopBarContent, tag: TaskTopBarHolder.Tag) { topBar.publish(content, tag: tag) }
    func clearTopBar(tag: TaskTopBarHolder.Tag) { topBar.clear(tag: tag) }
    func deactivateTopBar(tag: TaskTopBarHolder.Tag) { topBar.deactivate(tag) }

    /// Recomputes the selection's conversation against the current listing, so a shown conversation that went stale
    /// while the listing loaded is corrected, then accepts the writer if its conversation is the shown one.
    func retryTopBarActivation(tag: TaskTopBarHolder.Tag) {
        guard topBar.activeTag == nil else { return }
        if shownTopBarSubject() == tag.subject { topBar.setShownSubject(tag.subject) }
        topBar.activateIfVacant(tag)
    }

    func activateTopBar(tag: TaskTopBarHolder.Tag) {
        guard topBar.activeTag != tag else { return }
        if shownTopBarSubject() == tag.subject { topBar.setShownSubject(tag.subject) }
        topBar.activate(tag)
    }

    public func copyToPasteboard(_ text: String) -> Bool {
        _ = pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

// MARK: - StartScreenRouting

extension MainWindowCoordinator: StartScreenRouting {}

// MARK: - NeedsYouRouting

extension MainWindowCoordinator: NeedsYouRouting {
    func showNeedsYou(itemID: String?) {
        selection = .needsYou(itemID: itemID)
    }
}

// MARK: - ResourceSlotsRouting

extension MainWindowCoordinator: ResourceSlotsRouting {
    func openResourceSlotOwner(_ destination: ResourceSlotOwnerMetadata.Destination) {
        switch destination {
        case .task(let id):
            let logicalID = WorkflowOrchestratorConversation.members(containing: id, in: taskListRepository.tasks)?.first?.taskID ?? id
            resourceSlotsReturnDestination = .task(logicalID)
            selectTask(id)
        case .workflowRun(let id, _):
            resourceSlotsReturnDestination = .workflowRun(id)
            selection = .workflowRun(id)
        }
    }

    func invalidateResourceSlotsReturn() { resourceSlotsReturnDestination = nil }

    func showNewTask() { openNewSession() }

    func showResourceSlots() { selection = .resourceSlots }
}
