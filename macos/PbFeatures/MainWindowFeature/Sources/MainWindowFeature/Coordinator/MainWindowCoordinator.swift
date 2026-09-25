//
//  MainWindowCoordinator.swift
//  MainWindowFeature
//

import AppKit
import Combine
import Foundation
import MonitorCore
import PbCommon
import PbTerminal
import PbUI
import PbUtilities
import SwiftEnvironment
import SwiftUI

// MARK: - MainWindowNavigationCoordinator

/// Navigation/view-building contract for the main window's split view. `MainWindowNavigationView`
/// (this package) is generic over this protocol, never the concrete `MainWindowCoordinator` —
/// `selection` and `isNewSessionPresented` are the single source of truth the settled plan's
/// window/navigation seam formalises; the app target's root `AppCoordinator` (Phase 5) delegates
/// `.task`/`.group`/`.interactive`/`.newSession` straight onto `handle(path:)` for the
/// URL/notification/Cmd-N paths it owns (see that file's header).
@MainActor
public protocol MainWindowNavigationCoordinator: ViewChildCoordinator {
    /// The currently selected task/group/interactive-session destination, or `nil`. Never set to
    /// `.newSession`/`.openWindow` — those are handled separately (`isNewSessionPresented`, and the
    /// parent's own window-opening seam) — see `MainWindowCoordinator.handle(path:)`.
    var selection: MonitorDestination? { get set }
    func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never>
    
    /// Whether the New Session sheet is presented.
    var isNewSessionPresented: Bool { get set }
    func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never>
    
    /// Builds the sidebar (task list, search/filter, parallel runs, interactive sessions).
    func buildSidebarView() -> AnyView
    /// Builds the New Session sheet's content.
    func buildNewSessionView() -> AnyView
    /// Builds the Parallel screen for the group named `name`.
    func buildParallelView(name: String) -> AnyView
    /// Builds the task detail screen for `id`.
    func buildTaskDetailView(id: String) -> AnyView
    /// Builds the interactive-terminal screen for the session with `id`. A missing or closed
    /// session shows the closed-terminal state.
    func buildInteractiveView(id: UUID) -> AnyView
}

// MARK: - MainWindowCoordinator

/// The main window's coordinator: builds the Sidebar and New Session screens and owns the
/// navigation state above. `handle(path:)` applies its own destinations (`task`/`group`/
/// `interactive`/`newSession`) and bubbles anything else (`openWindow`, or a destination outside
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
    @ObservationIgnored @GlobalEnvironment(\.terminalSessionRegistry) private var terminalSessionRegistry
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    
    // MARK: - Init
    
    public init(parent: any Coordinator, terminalSessionRegistry: (any TerminalSessionRegistry)? = nil) {
        self.parent = parent
        if let terminalSessionRegistry { self.terminalSessionRegistry = terminalSessionRegistry }
        subscribeToEndedSessions()
    }
    
    /// Owns the "remove an ended interactive session unless it is selected" rule (settled plan's
    /// window/navigation seam; F4-21/F4-22), moved here from the app target's `AppModel` now that
    /// `selection` lives on this coordinator instead. The registry only publishes when a session
    /// ends — it never reads the selection itself. Takeover sessions are untouched: only
    /// `.interactive` ones are ever auto-removed.
    private func subscribeToEndedSessions() {
        terminalSessionRegistry.endedSessionsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] session in
                guard let self, case .interactive = session.kind else { return }
                if case .interactive(let id) = selection, id == session.id { return }
                terminalSessionRegistry.remove(session)
            }
            .store(in: &cancellables)
    }
    
    // MARK: - Public Methods
    
    public func handle(path: any PathDestination) {
        guard let destination = path as? MonitorDestination else {
            parent.handle(path: path)
            return
        }
        switch destination {
        case .task, .group, .interactive: selection = destination
        case .newSession: isNewSessionPresented = true
        case .openWindow: parent.handle(path: destination)
        }
    }
    
    public func selectionPublisher() -> AnyPublisher<MonitorDestination?, Never> { selectionSubject.eraseToAnyPublisher() }
    public func isNewSessionPresentedPublisher() -> AnyPublisher<Bool, Never> { isNewSessionPresentedSubject.eraseToAnyPublisher() }
    
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
        let useCase = ParallelViewRepository()
        let vm = ParallelVM(groupName: name, useCase: useCase, routing: self)
        return ParallelView(vm).id(name).eraseToAnyView()
    }
    
    /// A fresh VM every call, keyed by `id` exactly like `buildParallelView(name:)` above: `.id(id)`
    /// wraps the whole `TaskDetailView(vm)` value here, at the call site — never inside
    /// `TaskDetailView.body`, which owns no `@State` of its own (its `.id()` need is satisfied by
    /// this call site resetting the VM itself, not by an inner `.id()` the way the old
    /// `TaskDetailView`'s `EventScope` needed one). See `buildParallelView(name:)`'s header comment
    /// and the phase-4 brief's binding Lesson for why the placement matters.
    public func buildTaskDetailView(id: String) -> AnyView {
        let useCase = TaskDetailViewRepository()
        let vm = TaskDetailVM(taskID: id, useCase: useCase, routing: self)
        return TaskDetailView(vm).id(id).eraseToAnyView()
    }
    
    /// A fresh VM every call, keyed by `id` exactly like the two builders above. `InteractiveView`
    /// constructs `TaskDetail/Component/TerminalPaneView.swift` directly (same module) once its own
    /// `InteractiveVM` resolves a live session — this coordinator no longer exposes a standalone
    /// `buildTerminalPane` now that the app target's old `InteractiveView` (its only caller) is gone.
    public func buildInteractiveView(id: UUID) -> AnyView {
        let useCase = InteractiveViewRepository()
        let vm = InteractiveVM(sessionID: id, useCase: useCase, routing: self)
        return InteractiveView(vm).id(id).eraseToAnyView()
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
        let newVM = SidebarVM(useCase: useCase, routing: self)
        sidebarVM = newVM
        return newVM
    }
}

// MARK: - SidebarRouting

extension MainWindowCoordinator: SidebarRouting {
    public func select(_ destination: MonitorDestination?) {
        selection = destination
    }
    
    public func openNewSession() {
        isNewSessionPresented = true
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
    
    public func didStartInteractive(sessionID: UUID) {
        selection = .interactive(sessionID)
        isNewSessionPresented = false
    }
    
    public func dismiss() {
        isNewSessionPresented = false
    }
}

// MARK: - ParallelRouting

extension MainWindowCoordinator: ParallelRouting {
    public func selectTask(_ taskID: String) {
        selection = .task(taskID)
    }
}

// MARK: - TaskDetailRouting

extension MainWindowCoordinator: TaskDetailRouting {}

// MARK: - InteractiveRouting

/// `InteractiveRouting` declares no requirements (per this dispatch's own report): "Close" removes
/// the session through `InteractiveUseCase` and never touches selection, exactly as the app target's
/// old `AppModel.removeSession(_:)` never did either.
extension MainWindowCoordinator: InteractiveRouting {}
