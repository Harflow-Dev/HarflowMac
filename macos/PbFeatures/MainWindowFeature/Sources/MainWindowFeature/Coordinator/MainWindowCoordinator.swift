//
//  MainWindowCoordinator.swift
//  MainWindowFeature
//

import AppKit
import Combine
import Foundation
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import PbUtilities
import SwiftEnvironment
import SwiftUI

// MARK: - MainWindowNavigationCoordinator

/// Navigation/view-building contract for the main window's split view. `MainWindowNavigationView`
/// (this package) is generic over this protocol, never the concrete `MainWindowCoordinator` —
/// `selection` and `isNewSessionPresented` are the single source of truth the settled plan's
/// window/navigation seam formalises; the app target's root `AppCoordinator` (Phase 5) delegates
/// `.task`/`.group`/`.newSession` straight onto `handle(path:)` for the URL/notification/Cmd-N
/// paths it owns (see that file's header).
@MainActor
public protocol MainWindowNavigationCoordinator: ViewChildCoordinator {
    /// The currently selected task/group destination, or `nil`. Never set to
    /// `.newSession`/`.openWindow` — those are handled separately (`isNewSessionPresented`, and the
    /// parent's own window-opening seam) — see `MainWindowCoordinator.handle(path:)`.
    var selection: MonitorDestination? { get set }
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never>

    /// Whether the New Session sheet is presented.
    var isNewSessionPresented: Bool { get set }
    func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never>

    /// Builds the sidebar (task list, search/filter, parallel runs).
    func buildSidebarView() -> AnyView
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

    // MARK: - Public Properties

    public let parent: any Coordinator
    public var path: [PathDestination] { [] }

    public var selection: MonitorDestination? {
        didSet {
            guard selection != oldValue else { return }
            selectionSubject.send(selection)
        }
    }

    public var isNewSessionPresented = false {
        didSet {
            guard isNewSessionPresented != oldValue else { return }
            isNewSessionPresentedSubject.send(isNewSessionPresented)
        }
    }

    // MARK: - Private Properties

    @ObservationIgnored private let selectionSubject = PassthroughSubject<MonitorDestination?, Never>()
    @ObservationIgnored private let isNewSessionPresentedSubject = PassthroughSubject<Bool, Never>()
    @ObservationIgnored private var sidebarVM: SidebarVM?
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

    public init(parent: any Coordinator, pasteboard: any PasteboardWriting = NSPasteboard.general) {
        self.parent = parent
        self.pasteboard = pasteboard
    }

    // MARK: - Public Methods

    public func handle(path: any PathDestination) {
        guard let destination = path as? MonitorDestination else {
            parent.handle(path: path)
            return
        }
        switch destination {
        case .task(let id):
            selection = destination
            // Covers the URL/notification/menu-bar reveal triggers — `MenuBarCoordinator.select(_:)`
            // and the app target's URL/notification handling both bubble here (see this package's
            // `AGENTS.md`).
            requestReveal(taskID: id)
        case .group, .workflow, .newWorkflow, .workflowRun: selection = destination
        case .newSession: isNewSessionPresented = true
        case .openWindow: parent.handle(path: destination)
        }
    }

    public func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never> { selectionSubject.eraseToAnyPublisher() }
    public func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never> { isNewSessionPresentedSubject.eraseToAnyPublisher() }

    // MARK: - Pending reveal (settled plan, Design point 5)

    /// Records a fresh reveal request for `taskID` — a new `requestID` every time, repeats included,
    /// since `selection`'s own `didSet` drops a repeated assignment and would otherwise silently
    /// swallow navigating twice to the same already-selected, hidden task.
    private func requestReveal(taskID: String) {
        let reveal = PendingReveal(taskID: taskID, requestID: UUID())
        pendingReveal = reveal
        revealSubject.send(reveal)
    }

    public func buildSidebarView() -> AnyView {
        SidebarView(sharedSidebarVM()).eraseToAnyView()
    }
    
    /// A fresh VM every call, deliberately not cached: the sheet's defaults (claude/interactive/
    /// read_only, empty repo/message) must reappear every time it opens, exactly as the old
    /// `NewSessionSheet`'s `@State` did on each reconstruction (MS-NS-1).
    public func buildNewSessionView() -> AnyView {
        let useCase = NewSessionViewRepository()
        let vm = NewSessionVM(useCase: useCase, routing: self)
        return NewSessionView(vm).eraseToAnyView()
    }
    
    /// A fresh VM every call: the app target's detail pane switches `.group(let name):` inside a
    /// plain `switch`, not a coordinator-owned navigation stack, so this is called on every render
    /// of that switch case. `.id(name)` is applied **here**, wrapping the whole `ParallelView(vm)`
    /// value, not inside `ParallelView.body` — `ParallelView` itself owns `@State var viewModel`, and
    /// that state is tied to *its own* identity as seen by this call site, not to anything inside its
    /// body. An `.id()` applied inside `body` only re-identifies that body's descendants, so it
    /// cannot reset `ParallelView`'s own `@State` when `name` changes (a real bug caught in review:
    /// selecting a different group kept showing the previous group's VM and leases). Applying it here
    /// makes SwiftUI treat two different group names as two different view identities — discarding
    /// the old `@State`-held VM (running its `didDisappear()`) and adopting the fresh one passed in —
    /// while same-name re-renders keep reusing the existing VM as intended.
    /// (`TaskDetailView.swift`'s analogous `.id(taskID)` works differently and is not a counter-
    /// example: that view holds no `@State` of its own, so applying `.id()` inside its body to
    /// `EventScope` — which does hold `@State` — is the correct spot there.)
    ///
    /// `withPresentationContext()` (`PbUI`) is applied once, at `MainWindowNavigationView`'s own
    /// root — not here any more. Applying it a second time per screen (as an earlier phase did) would
    /// give Parallel/TaskDetail their own isolated `@Environment(\.viewEvent)`, nested inside the one
    /// the navigation view already provides, which is harmless only by accident; moving it up here
    /// keeps every screen sharing the single environment/state the window root owns.
    public func buildParallelView(name: String) -> AnyView {
        // A group of one agent is not a parallel run: it gets the ordinary task screen.
        if let taskID = Self.soleConversationID(inGroup: name, tasks: taskListRepository.tasks) {
            return buildTaskDetailView(id: taskID)
        }
        let useCase = ParallelViewRepository()
        let vm = ParallelVM(groupName: name, useCase: useCase, routing: self)
        return ParallelView(vm).id(name).eraseToAnyView()
    }
    
    /// The first task of the group's only agent conversation, or `nil` when the group has none or
    /// several (then it is a real parallel run). Membership is read when the view is built.
    nonisolated static func soleConversationID(inGroup name: String, tasks: [TaskInfo]) -> String? {
        guard let group = Lineage.sections(tasks).parallel.first(where: { $0.name == name }),
              group.conversations.count == 1 else { return nil }
        return group.conversations[0].first.taskID
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
        let vm = TaskDetailVM(taskID: id, useCase: useCase, routing: self)
        let conversationID = Lineage.conversationID(of: id, in: taskListRepository.tasks)
        return TaskDetailView(vm).id(conversationID).eraseToAnyView()
    }
    
    // MARK: - ViewCoordinator
    
    /// The main window's whole `NavigationSplitView`, per this dispatch's own instruction — not just
    /// the sidebar any more.
    public func start() -> AnyView {
        MainWindowNavigationView(self).eraseToAnyView()
    }
    
    // MARK: - Private Methods
    
    private func sharedSidebarVM() -> SidebarVM {
        if let sidebarVM { return sidebarVM }
        let useCase = SidebarViewRepository()
        let newVM = SidebarVM(useCase: useCase, routing: self, workflowUseCase: useCase)
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
        selection = .task(taskID)
        requestReveal(taskID: taskID)
    }
}

// MARK: - TaskDetailRouting

extension MainWindowCoordinator: TaskDetailRouting {
    public func copyToPasteboard(_ text: String) -> Bool {
        _ = pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}
