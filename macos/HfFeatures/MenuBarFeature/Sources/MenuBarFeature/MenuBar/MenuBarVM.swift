//
//  MenuBarVM.swift
//  MenuBarFeature
//

import Combine
import Foundation
import HfCommon
import HfRepository
import HfUI
import HfUtilities
import Mockable
import MonitorCore

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
    /// The catalog counts/readiness channel: the always-visible label's running count and its
    /// loading state, published even when the task array itself has not changed — the label must
    /// not depend on the popover-only rows recomputing.
    func countsPublisher() -> AnyPublisher<TaskListCounts, Never>

    var connectionLine: String { get }
    var runningCount: Int { get }
    /// Whether the managed runtime is ready (`InstallRepository.setupState.isReady`).
    var runtimeReady: Bool { get }
    /// Deduplicated runtime readiness. May emit off the main thread.
    func runtimeReadyPublisher() -> AnyPublisher<Bool, Never>
    
    func title(_ taskID: String) -> String
    
    /// Decision 6: a lease acquired while a running row is on screen, released when it is not.
    func acquireEventLease(_ taskID: String) -> any EventStreamLease
    func itemsPublisher(_ taskID: String) -> AnyPublisher<[TimelineItem], Never>
    /// The latest tool call still waiting for its result, if any (`EventStreamRepository.current`).
    func current(_ taskID: String) -> TimelineItem?

    // MARK: Install (settled plan, section 5)

    func installStatePublisher() -> AnyPublisher<InstallState, Never>
    var installState: InstallState { get }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never>
    var lastCheckMessage: String? { get }
    func retry() async
    func reset()
}

@MainActor
protocol MenuBarCountAvailabilityUseCase {
    var countsComplete: Bool { get }
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
    let workflowStatus: WorkflowMenuBarStatusVM?
    var workflowRows: [WorkflowMenuBarRow] { workflowStatus?.rows ?? [] }
    var workflowActiveCount: Int { workflowStatus?.activeCount ?? 0 }
    var workflowAttentionCount: Int { workflowStatus?.attentionCount ?? 0 }
    private(set) var taskCountsLoading = false
    var workflowCountsLoading: Bool { workflowStatus?.countsLoading ?? false }
    var workflowStatusError: String? { workflowStatus?.errorText }
    
    // MARK: - MenuBarViewModel Properties
    
    private(set) var runningRows: [MenuBarRunningRowModel] = []
    private(set) var recentGroups: [ParallelGroup] = []
    private(set) var recentTasks: [TaskRowModel] = []
    private(set) var listErrorMessage: String?
    private(set) var isConnected = false
    private(set) var connectionLine: String
    private(set) var runningCount: Int
    /// Whether the managed runtime is ready. The new-session button is disabled and the tap ignored
    /// while it is not, since the main window drops the request until the runtime is ready.
    private(set) var canStartNewSession: Bool
    /// The popover header's subline: "harflow connected" while the list is healthy, else the
    /// repository's own connection line (connecting / error wording). No per-backend health claims.
    var headerSubline: String { isConnected ? "harflow connected" : connectionLine }
    /// The install/update banner to show where the red list error shows today, or `nil` when
    /// nothing needs surfacing (settled plan, section 5's precedence rules).
    private(set) var installBannerModel: InstallBanner.Model?
    /// The Needs you section; nil until the first complete pass. Subscribed while the popover is open.
    var needsYou: MenuBarNeedsYouSection?
    @ObservationIgnored var approvalSubmitting: Set<String> = []
    @ObservationIgnored var approvalResults: [String: MenuBarApprovalHeldResult] = [:]

    // MARK: - Private Properties

    @ObservationIgnored private let useCase: any MenuBarUseCase
    @ObservationIgnored let routing: any MenuBarRouting
    /// Whether anyone can see the Monitor: feeds the popover-open state (the popover's own
    /// appear/disappear is the one reliable `MenuBarExtra` signal) and paces the minute tick's
    /// popover-content recompute.
    @ObservationIgnored let visibility: any MonitorVisibility
    /// The minute-aligned presentation clock's scheduler seam.
    @ObservationIgnored let scheduler: any Scheduling
    @ObservationIgnored var minuteTickToken: AnyCancellable?
    @ObservationIgnored var minuteRepeatToken: AnyCancellable?
    /// Bumped on every stop, so a one-shot already queued on the main actor can tell it is stale.
    @ObservationIgnored var minuteTickGeneration = 0
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()
    @ObservationIgnored private var didSubscribe = false
    @ObservationIgnored var needsYouSubscription: AnyCancellable?
    @ObservationIgnored let needsYouSource: (any MenuBarNeedsYouUseCase)?
    @ObservationIgnored private var latestTasks: [TaskInfo] = []
    @ObservationIgnored private var latestListError: ToolError?
    @ObservationIgnored private var latestHasListed = false
    @ObservationIgnored private var activityLines: [String: (text: String, monospaced: Bool)] = [:]
    @ObservationIgnored private var rowLeases: [String: any EventStreamLease] = [:]
    @ObservationIgnored private var rowCancellables: [String: AnyCancellable] = [:]
    @ObservationIgnored private var installState: InstallState = .idle
    @ObservationIgnored private var lastCheckMessage: String?

    // MARK: - Init

    init(useCase: any MenuBarUseCase, routing: any MenuBarRouting, workflowStatus: WorkflowMenuBarStatusVM? = nil,
         visibility: any MonitorVisibility, scheduler: any Scheduling, needsYou needsYouSource: (any MenuBarNeedsYouUseCase)? = nil) {
        self.needsYouSource = needsYouSource
        self.workflowStatus = workflowStatus
        self.useCase = useCase
        self.routing = routing
        self.visibility = visibility
        self.scheduler = scheduler
        self.connectionLine = useCase.connectionLine
        self.runningCount = useCase.runningCount
        self.canStartNewSession = useCase.runtimeReady
        self.taskCountsLoading = !((useCase as? any MenuBarCountAvailabilityUseCase)?.countsComplete ?? true)
        self.installState = useCase.installState
        self.lastCheckMessage = useCase.lastCheckMessage
        recomputeInstallBanner()
    }
    
    // MARK: - MenuBarViewModel Methods
    
    func didAppear() {
        // Seed readiness synchronously so the workflow poll never starts against a stale default.
        workflowStatus?.setRuntimeReady(useCase.runtimeReady)
        workflowStatus?.didAppear()
        subscribeIfNeeded()
        subscribeToNeedsYou()
    }

    /// The popover content appeared — distinct from `didAppear()`, which the always-on-screen
    /// label view also fires, so it cannot mean "the popover opened". This is the one reliable
    /// `MenuBarExtra` open/close signal, fed to `MonitorVisibility` (the workflow poll and the
    /// popover-content recompute pace off it) and used to refresh the popover's time-derived
    /// presentation immediately and re-align the minute tick.
    func didPopoverOpen() {
        visibility.setMenuBarPopoverOpen(true)
        restartMinuteTick()
        recompute()
    }

    /// The popover content disappeared — see `didPopoverOpen()` for why this is its own method.
    func didPopoverClose() {
        visibility.setMenuBarPopoverOpen(false)
        stopMinuteTick()
    }

    func didDisappearStatusItem() { workflowStatus?.didDisappear() }

    func didSelectWorkflow(_ runID: String) {
        routing.select(.workflowRun(runID))
        routing.openWindow()
    }
    
    /// See the type-level comment: this deliberately does not tear down the core subscriptions,
    /// only the per-row event leases.
    func didDisappear() {
        needsYouSubscription?.cancel()
        needsYouSubscription = nil
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
    
    func didTapNewSession() {
        guard canStartNewSession else { return }
        routing.select(.newSession)
    }
    
    func didCaptureWindowOpener(_ opener: @escaping () -> Void) {
        routing.registerWindowOpener(opener)
    }

    // MARK: - Install banner actions (settled plan, section 5)

    func didTapInstallBannerPrimary() {
        if case .failed = installState {
            Task { [weak self] in await self?.useCase.retry() }
        }
    }

    func didTapInstallBannerDismiss() {
        useCase.reset()
    }

    // MARK: - Private Methods

    /// See the type-level comment: the install-state subscriptions join the core group here — they
    /// are part of the same "survives the popover closing" group as `tasksPublisher`/etc., not the
    /// per-row leases `didDisappear()` tears down.
    private func subscribeIfNeeded() {
        guard !didSubscribe else { return }
        didSubscribe = true

        useCase.tasksPublisher()
            .receive(on: DispatchQueue.main)
            // The producer dedupes duration-drifted equivalents, so an emission here is a real
            // change. (Codex review round 1, finding 2's republish-as-clock is replaced by the
            // minute-aligned tick below: relative ages/finished-task ages refresh there, and
            // running elapsed labels already tick in their own `TimelineView`.)
            .sink { [weak self] tasks in
                guard let self else { return }
                latestTasks = tasks
                recompute()
            }
            .store(in: &cancellables)

        useCase.runtimeReadyPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ready in
                guard let self else { return }
                if canStartNewSession != ready { canStartNewSession = ready }
                workflowStatus?.setRuntimeReady(ready)
            }
            .store(in: &cancellables)

        useCase.countsPublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] counts in
                guard let self else { return }
                // The always-visible label's own channel: the running count and its loading state
                // update without the popover-only rows recomputing.
                if runningCount != counts.runningCount { runningCount = counts.runningCount }
                if taskCountsLoading == counts.countsComplete { taskCountsLoading = !counts.countsComplete }
            }
            .store(in: &cancellables)

        useCase.listErrorPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] error in
                guard let self else { return }
                latestListError = error
                listErrorMessage = error?.isManagedRuntimeUnavailable != true ? error?.message : nil
                recomputeInstallBanner()
                recompute()
            }
            .store(in: &cancellables)

        subscribeToInstallState()

        useCase.hasListedPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] hasListed in
                guard let self else { return }
                latestHasListed = hasListed
                recompute()
            }
            .store(in: &cancellables)

        useCase.titlesPublisher()
            .receive(on: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in self?.recompute() }
            .store(in: &cancellables)
    }
    
    /// Recomputes every derived list from `latestTasks`/`latestListError`/`latestHasListed`. Mirrors
    /// the old `MenuBarView.body`'s inline `Lineage.sections`/`filter`/`sorted` exactly, including
    /// the undefined-order existing issue (roots/sub-tasks are not given a stabilising sort).
    func recompute() {
        isConnected = latestListError == nil && latestHasListed
        connectionLine = useCase.connectionLine
        runningCount = useCase.runningCount
        taskCountsLoading = !((useCase as? any MenuBarCountAvailabilityUseCase)?.countsComplete ?? true)
        
        let running = latestTasks
            .filter(\.status.isRunning)
            .sorted { ($0.isRoot ? 0 : 1) < ($1.isRoot ? 0 : 1) }
        runningRows = running.map { task in
            let activity = activityLines[task.taskID]
            return MenuBarRunningRowModel(
                id: task.taskID,
                backend: task.backend,
                title: useCase.title(task.taskID),
                repoName: Format.repoName(task.repoPath),
                startedAt: task.startedAt,
                durationSeconds: task.durationSeconds,
                activityLine: activity?.text,
                activityIsMonospaced: activity?.monospaced ?? false
            )
        }
        
        // Parallel groups stay task-level (Review round 1, item 3); Recent shows conversations —
        // one entry per resume chain (Monitor piece 7), named by its first member, statused by its
        // current, so a follow-up sent to a finished task does not also leave its old row behind.
        recentGroups = Array(Lineage.sections(latestTasks).parallel.prefix(3))
        let conversations = Lineage.conversationSections(latestTasks).recent
        recentTasks = conversations.prefix(6).map { node in
            let current = node.conversation.current
            return TaskRowModel(
                id: node.id,
                backend: current.backend,
                title: useCase.title(node.conversation.first.taskID),
                status: current.status,
                repoName: Format.repoName(current.repoPath),
                ageText: Format.age(current.startedAt)
            )
        }
    }
    
    /// Mirrors the old `MenuRunningRow`: the current tool call still waiting for a result wins
    /// (monospaced, `tool headline`), else the last assistant text (regular weight), else nothing.
    private func updateActivityLine(_ taskID: String, items: [TimelineItem]) {
        if let current = useCase.current(taskID), case .tool(let call, _) = current.body {
            activityLines[taskID] = ("\(call.tool) \(call.headline)", true)
        } else if let last = items.last(where: { if case .text = $0.body { true } else { false } }), case .text(let text, _) = last.body {
            activityLines[taskID] = (text, false)
        } else {
            activityLines[taskID] = nil
        }
        recompute()
    }
}

// MARK: - MenuBarVM + Install banner

/// Maps `InstallState` to `InstallBanner.Model`. HfUI can't see `InstallState` (Core doesn't depend
/// on UI), so this mapping lives here — a small, per-feature helper duplicated in `HarnessesVM`.
extension MenuBarVM {

    /// Split out of `subscribeIfNeeded()` to keep that function within the lint length budget.
    private func subscribeToInstallState() {
        useCase.installStatePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                installState = state
                recomputeInstallBanner()
            }
            .store(in: &cancellables)

        useCase.lastCheckMessagePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                lastCheckMessage = message
                recomputeInstallBanner()
            }
            .store(in: &cancellables)
    }

    private func recomputeInstallBanner() {
        switch installState {
        case .running(let stage):
            installBannerModel = InstallBanner.Model(title: Self.runningTitle(stage), detail: Self.runningDetail(stage), isBusy: true)
        case .failed(_, let message):
            installBannerModel = InstallBanner.Model(
                title: "Harflow runtime preparation failed",
                detail: "The managed runtime is unavailable. Try again to prepare it.",
                primaryTitle: "Try again",
                errorText: message,
                canDismiss: true
            )
        case .idle, .installed:
            // A current tool error outranks the success banner: the plain red `listErrorMessage` shows instead.
            if latestListError == nil, installState == .installed {
                installBannerModel = InstallBanner.Model(
                    title: "harflow is installed",
                    detail: "The new install passed its checks.",
                    canDismiss: true,
                    footnote: "Next: register it with your harnesses in Settings → Harnesses."
                )
            } else {
                installBannerModel = nil
            }
        }
    }
}
