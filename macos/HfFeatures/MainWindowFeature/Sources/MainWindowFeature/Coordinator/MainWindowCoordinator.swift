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

// MARK: - MainWindowSheet

/// Mutually exclusive modal destinations presented by the main window.
public enum MainWindowSheet: String, Identifiable {
    /// Starts a new headless session.
    case newSession
    /// Chooses and launches a saved workflow.
    case workflowRunner

    /// Stable identity for the presented destination.
    public var id: String { rawValue }
}

// MARK: - MainWindowNavigationCoordinator

/// Navigation/view-building contract for the main window's split view. `MainWindowNavigationView`
/// (this package) is generic over this protocol, never the concrete `MainWindowCoordinator` —
/// `selection` and `presentedSheet` are the single source of truth the settled plan's
/// window/navigation seam formalises; the app target's root `AppCoordinator` (Phase 5) delegates
/// `.task`/`.group`/`.newSession` straight onto `handle(path:)` for the URL/notification/Cmd-N
/// paths it owns (see that file's header).
@MainActor
public protocol MainWindowNavigationCoordinator: ViewChildCoordinator {
    /// The currently selected task/group destination, or `nil`. Never set to
    /// `.newSession`/`.openWindow` — those are handled separately (`presentedSheet`, and the
    /// parent's own window-opening seam) — see `MainWindowCoordinator.handle(path:)`.
    var runtimeIsReady: Bool { get }
    var selection: MonitorDestination? { get set }
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never>

    /// The main window's mutually exclusive modal destination.
    var presentedSheet: MainWindowSheet? { get set }

    /// Compatibility projection of the New Session destination; false dismisses only that destination.
    var isNewSessionPresented: Bool { get set }
    func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never>

    /// Presents the saved-workflow chooser and existing launch flow independently of editor focus.
    func presentWorkflowRunner()
    /// Compatibility projection of the workflow runner destination; false dismisses only that destination.
    var isWorkflowRunnerPresented: Bool { get set }
    /// Builds the saved-workflow chooser and launch sheet.
    func buildWorkflowRunnerView() -> AnyView

    /// Builds retained finished-work Statistics.
    func buildStatisticsView() -> AnyView
    /// Builds the ready runtime start screen.
    func buildStartScreenView() -> AnyView
    /// Builds the sidebar (task list, search/filter, parallel runs).
    func buildSidebarView() -> AnyView
    /// Builds the main window title's connection indicator.
    func buildConnectionStatusView() -> AnyView
    /// Builds the New Session sheet's content.
    func buildNewSessionView() -> AnyView
    /// Builds the Parallel screen for the group named `name`.
    func buildParallelView(name: String) -> AnyView
    /// Builds the task detail screen for `id`.
    func buildTaskDetailView(id: String) -> AnyView
    /// Builds the workflow library and execution monitor.
    func buildWorkflowEditorView(name: String?) -> AnyView
    /// Builds the monitor for a persisted workflow run.
    func buildWorkflowRunView(id: String) -> AnyView
}

public extension MainWindowNavigationCoordinator {
    var runtimeIsReady: Bool { true }
    func buildStartScreenView() -> AnyView { AnyView(EmptyView()) }
    func buildConnectionStatusView() -> AnyView { AnyView(EmptyView()) }

    func buildStatisticsView() -> AnyView { AnyView(EmptyView()) }

    /// Derives modal state for lightweight preview and test coordinators.
    var presentedSheet: MainWindowSheet? {
        get {
            if isNewSessionPresented { return .newSession }
            return isWorkflowRunnerPresented ? .workflowRunner : nil
        }
        set {
            isNewSessionPresented = newValue == .newSession
            isWorkflowRunnerPresented = newValue == .workflowRunner
        }
    }
}

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

    // MARK: - Public Properties

    public let parent: any Coordinator
    public var path: [PathDestination] { [] }

    public var selection: MonitorDestination? {
        didSet {
            guard selection != oldValue else { return }
            selectionSubject.send(selection)
        }
    }

    public var presentedSheet: MainWindowSheet? {
        didSet {
            if presentedSheet != .workflowRunner { initialWorkflowRunnerName = nil }
            if presentedSheet != nil, !runtimeIsReady { presentedSheet = nil; return }
            let wasNewSession = oldValue == .newSession
            let isNewSession = presentedSheet == .newSession
            guard wasNewSession != isNewSession else { return }
            isNewSessionPresentedSubject.send(isNewSession)
        }
    }

    public var isNewSessionPresented: Bool {
        get { presentedSheet == .newSession }
        set {
            if newValue {
                presentedSheet = .newSession
            } else if presentedSheet == .newSession {
                presentedSheet = nil
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
    @ObservationIgnored private var runtimeSubscription: AnyCancellable?

    // MARK: - Private Properties

    @ObservationIgnored private let selectionSubject = CurrentValueSubject<MonitorDestination?, Never>(nil)
    @ObservationIgnored private let isNewSessionPresentedSubject = CurrentValueSubject<Bool, Never>(false)
    @ObservationIgnored let workflowRunPolling = WorkflowRunPolling()
    @ObservationIgnored private var sidebarVM: SidebarVM?
    @ObservationIgnored private var startScreenVM: StartScreenVM?
    @ObservationIgnored private var statisticsVM: StatisticsVM?
    @ObservationIgnored private let pasteboard: any PasteboardWriting
    /// The latest unconsumed navigation-triggered reveal (settled plan, Design point 5's
    /// "coordinator owns the pending reveal") — set on every navigation request for a task, so it
    /// survives even while the sidebar is unsubscribed (window closed).
    @ObservationIgnored private(set) var pendingReveal: PendingReveal?
    @ObservationIgnored private let revealSubject = PassthroughSubject<PendingReveal, Never>()
    /// Read only to normalise `buildTaskDetailView(id:)`'s `.id()` key (Monitor piece 7, Review
    /// round 1 item 4) — never to drive any other coordinator behaviour.
    @ObservationIgnored @GlobalEnvironment(\.taskListRepository) private var taskListRepository

    // MARK: - Init

    public init(
        parent: any Coordinator,
        pasteboard: any PasteboardWriting = NSPasteboard.general,
        installRepository: (any InstallRepository)? = nil
    ) {
        self.parent = parent
        self.pasteboard = pasteboard
        let install = installRepository ?? GlobalValues.installRepository
        self.runtimeIsReady = install.setupState.isReady
        self.runtimeSubscription = install.setupStatePublisher().receive(on: DispatchQueue.main).sink { [weak self] state in
            guard let self else { return }
            if runtimeIsReady != state.isReady { self.runtimeIsReady = state.isReady }
            if !state.isReady { self.presentedSheet = nil }
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
            case .newSession, .newWorkflow, .workflow: return
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
        case .group, .workflow, .newWorkflow, .workflowRun, .statistics: selection = destination
        case .newSession: isNewSessionPresented = true
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

    public func buildSidebarView() -> AnyView {
        SidebarView(sharedSidebarVM()).eraseToAnyView()
    }

    public func buildConnectionStatusView() -> AnyView {
        ConnectionStatusView(ConnectionStatusVM(useCase: SidebarViewRepository())).eraseToAnyView()
    }
    
    /// A fresh VM every call, deliberately not cached: the sheet's defaults (claude/interactive/
    /// read_only, empty repo/message) must reappear every time it opens, exactly as the old
    /// `NewSessionSheet`'s `@State` did on each reconstruction (MS-NS-1).
    public func buildNewSessionView() -> AnyView {
        let useCase = NewSessionViewRepository()
        let vm = NewSessionVM(useCase: useCase, routing: self)
        return NewSessionView(vm).eraseToAnyView()
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
            makeDetail: { [self] id in
                TaskDetailVM(taskID: id, useCase: TaskDetailViewRepository(), routing: self, continuityHistory: continuityHistory)
            },
            makeParallel: { [self] in
                ParallelVM(groupName: name, useCase: ParallelViewRepository(), routing: self, horizontalPosition: parallelPosition(for: "group:" + name))
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
    /// SAME conversation must keep the identical VM instance — its own tab selection and message
    /// draft — rather than rebuilding on every such navigation. `TaskDetailVM` itself is still built
    /// with the raw `id`; it resolves the whole conversation from whichever member it is given.
    public func buildTaskDetailView(id: String) -> AnyView {
        let useCase = TaskDetailViewRepository()
        let vm = TaskDetailVM(taskID: id, useCase: useCase, routing: self, continuityHistory: continuityHistory)
        let conversationID = WorkflowOrchestratorConversation.members(containing: id, in: taskListRepository.tasks)?.first?.taskID
            ?? Lineage.conversationID(of: id, in: taskListRepository.tasks)
        return TaskDetailView(vm).id(conversationID).eraseToAnyView()
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
            case .newSession, .newWorkflow, .workflow: return
            default: break
            }
        }
        selection = destination
    }

    public func openNewSession() {
        isNewSessionPresented = true
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
        isNewSessionPresented = false
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

// MARK: - TaskDetailRouting

extension MainWindowCoordinator: TaskDetailRouting {
    public func copyToPasteboard(_ text: String) -> Bool {
        _ = pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

// MARK: - StartScreenRouting

extension MainWindowCoordinator: StartScreenRouting {}
