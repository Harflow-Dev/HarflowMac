//
//  MenuBarVM.swift
//  MenuBarFeature
//

import Combine
import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbUI
import PbUtilities

// MARK: - MenuBarUseCase

/// The menu bar's data needs over `TaskListRepository`, `SettingsRepository` and
/// `EventStreamRepository`.
@Mockable
@MainActor
protocol MenuBarUseCase: Sendable {
    
    func tasksPublisher() -> AnyPublisher<[TaskInfo], Never>
    func listErrorPublisher() -> AnyPublisher<ToolError?, Never>
    func hasListedPublisher() -> AnyPublisher<Bool, Never>
    /// Titles resolve asynchronously after a task first lists — Sidebar/Parallel both recompute
    /// their rows when this fires, and the menu bar must too, or a row can be stuck on a placeholder
    /// title after the real one loads.
    func titlesPublisher() -> AnyPublisher<[String: String], Never>
    func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never>
    func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never>
    
    var openWindowOnStart: Bool { get }
    var notifyOnFinish: Bool { get }
    var connectionLine: String { get }
    var runningCount: Int { get }
    
    func title(_ taskID: String) -> String
    func setOpenWindowOnStart(_ value: Bool)
    func setNotifyOnFinish(_ value: Bool)
    
    /// Decision 6: a lease acquired while a running row is on screen, released when it is not.
    func acquireEventLease(_ taskID: String) -> any EventStreamLease
    func itemsPublisher(_ taskID: String) -> AnyPublisher<[TimelineItem], Never>
    /// The latest tool call still waiting for its result, if any (`EventStreamRepository.current`).
    func current(_ taskID: String) -> TimelineItem?
}

// MARK: - MenuBarRouting

/// Navigation the menu bar performs — always through the coordinator, never a direct `AppModel`
/// reference (Features never import the app target).
@Mockable
@MainActor
protocol MenuBarRouting: Sendable {
    /// Selects a task or group. Does not itself bring the window forward — pair with `openWindow()`
    /// when the action should do both, as every menu-bar "open an item" action does.
    func select(_ destination: MonitorDestination)
    func openWindow()
    /// Registers the window-opening closure captured by `MenuBarLabelView.onAppear`.
    func registerWindowOpener(_ opener: @escaping () -> Void)
}

// MARK: - MenuBarVM

/// View model for the menu bar (label + popover content).
///
/// **Judgement call, disclosed:** `didDisappear()` is called when the popover closes, but it does
/// **not** cancel the core `tasksPublisher`/`listErrorPublisher`/`hasListedPublisher`/settings
/// subscriptions the way the architecture rule's teardown example literally suggests. Those stay
/// alive for the process's lifetime once first subscribed (from `MenuBarLabelView`'s `didAppear()`,
/// which fires immediately at launch since the status item is always on screen — see
/// `MenuBarLabelView`). Tearing them down whenever the popover closes would silently stop the
/// always-visible label's running-count badge from updating, which would have been a real regression against
/// the pre-refactor `AppModel`-backed behaviour (the count was driven by a subscription set up once
/// in `AppModel.init`, never torn down). `didDisappear()` only releases the per-row event leases —
/// the one thing this screen actually needs to stop tailing once its rows are off screen.
@Observable
@MainActor
final class MenuBarVM: MenuBarViewModel {
    
    // MARK: - MenuBarViewModel Properties
    
    private(set) var runningRows: [MenuBarRunningRowModel] = []
    private(set) var recentGroups: [ParallelGroup] = []
    private(set) var recentTasks: [TaskRowModel] = []
    private(set) var listErrorMessage: String?
    private(set) var isConnected = false
    private(set) var connectionLine: String
    private(set) var runningCount: Int
    private(set) var openWindowOnStart: Bool
    private(set) var notifyOnFinish: Bool
    
    // MARK: - Private Properties
    
    @ObservationIgnored private let useCase: any MenuBarUseCase
    @ObservationIgnored private let routing: any MenuBarRouting
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored private var latestTasks: [TaskInfo] = []
    @ObservationIgnored private var latestListError: ToolError?
    @ObservationIgnored private var latestHasListed = false
    @ObservationIgnored private var activityLines: [String: (text: String, monospaced: Bool)] = [:]
    @ObservationIgnored private var rowLeases: [String: any EventStreamLease] = [:]
    @ObservationIgnored private var rowCancellables: [String: AnyCancellable] = [:]
    
    // MARK: - Init
    
    init(useCase: any MenuBarUseCase, routing: any MenuBarRouting) {
        self.useCase = useCase
        self.routing = routing
        self.connectionLine = useCase.connectionLine
        self.runningCount = useCase.runningCount
        self.openWindowOnStart = useCase.openWindowOnStart
        self.notifyOnFinish = useCase.notifyOnFinish
    }
    
    // MARK: - MenuBarViewModel Methods
    
    func didAppear() {
        subscribeIfNeeded()
    }
    
    /// See the type-level comment: this deliberately does not tear down the core subscriptions,
    /// only the per-row event leases.
    func didDisappear() {
        for (_, lease) in rowLeases { lease.release() }
        rowLeases.removeAll()
        rowCancellables.removeAll()
        activityLines.removeAll()
    }
    
    func didAppearRunningRow(_ taskID: String) {
        guard rowLeases[taskID] == nil else { return }
        rowLeases[taskID] = useCase.acquireEventLease(taskID)
        rowCancellables[taskID] = useCase.itemsPublisher(taskID)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.updateActivityLine(taskID, items: items) }
    }
    
    func didDisappearRunningRow(_ taskID: String) {
        rowLeases[taskID]?.release()
        rowLeases[taskID] = nil
        rowCancellables[taskID] = nil
        activityLines[taskID] = nil
    }
    
    func didSelectRunningTask(_ taskID: String) {
        routing.select(.task(taskID))
        routing.openWindow()
    }
    
    func didSelectRecentTask(_ taskID: String) {
        routing.select(.task(taskID))
        routing.openWindow()
    }
    
    func didSelectGroup(_ name: String) {
        routing.select(.group(name))
        routing.openWindow()
    }
    
    func didTapOpenMonitor() {
        routing.openWindow()
    }
    
    func didToggleOpenWindowOnStart(_ isOn: Bool) {
        useCase.setOpenWindowOnStart(isOn)
    }
    
    func didToggleNotifyOnFinish(_ isOn: Bool) {
        useCase.setNotifyOnFinish(isOn)
    }
    
    func didCaptureWindowOpener(_ opener: @escaping () -> Void) {
        routing.registerWindowOpener(opener)
    }
    
    // MARK: - Private Methods
    
    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true
        
        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] tasks in
                guard let self else { return }
                latestTasks = tasks
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.listErrorPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] error in
                guard let self else { return }
                latestListError = error
                listErrorMessage = error?.message
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasListed in
                guard let self else { return }
                latestHasListed = hasListed
                recompute()
            }
            .store(in: &cancellables)
        
        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
        
        useCase.openWindowOnStartPublisher()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.openWindowOnStart, on: self)
            .store(in: &cancellables)
        
        useCase.notifyOnFinishPublisher()
            .receive(on: DispatchQueue.main)
            .weakAssign(to: \.notifyOnFinish, on: self)
            .store(in: &cancellables)
    }
    
    /// Recomputes every derived list from `latestTasks`/`latestListError`/`latestHasListed`. Mirrors
    /// the old `MenuBarView.body`'s inline `Lineage.sections`/`filter`/`sorted` exactly, including
    /// the undefined-order existing issue (roots/sub-tasks are not given a stabilising sort).
    private func recompute() {
        isConnected = latestListError == nil && latestHasListed
        connectionLine = useCase.connectionLine
        runningCount = useCase.runningCount
        
        let running = latestTasks
            .filter(\.status.isRunning)
            .sorted { ($0.isRoot ? 0 : 1) < ($1.isRoot ? 0 : 1) }
        runningRows = running.map { task in
            let activity = activityLines[task.taskID]
            return MenuBarRunningRowModel(
                id: task.taskID,
                backend: task.backend,
                title: useCase.title(task.taskID),
                startedAt: task.startedAt,
                durationSeconds: task.durationSeconds,
                activityLine: activity?.text,
                activityIsMonospaced: activity?.monospaced ?? false
            )
        }
        
        let sections = Lineage.sections(latestTasks)
        recentGroups = Array(sections.parallel.prefix(3))
        recentTasks = sections.recent.prefix(6).map { node in
            TaskRowModel(
                id: node.id,
                backend: node.task.backend,
                title: useCase.title(node.id),
                statusLabel: node.task.status.label,
                statusColor: StatusColor.of(node.task.status),
                ageText: Format.age(node.task.startedAt)
            )
        }
    }
    
    /// Mirrors the old `MenuRunningRow`: the current tool call still waiting for a result wins
    /// (monospaced, `tool headline`), else the last assistant text (regular weight), else nothing.
    private func updateActivityLine(_ taskID: String, items: [TimelineItem]) {
        if let current = useCase.current(taskID), case .tool(let call, _) = current.body {
            activityLines[taskID] = ("\(call.tool) \(call.headline)", true)
        } else if let last = items.last, case .text(let text) = last.body {
            activityLines[taskID] = (text, false)
        } else {
            activityLines[taskID] = nil
        }
        recompute()
    }
}
