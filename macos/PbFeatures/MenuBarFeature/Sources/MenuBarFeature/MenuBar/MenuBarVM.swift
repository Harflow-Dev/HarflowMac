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

    // MARK: Install (settled plan, section 5)

    func installStatePublisher() -> AnyPublisher<InstallState, Never>
    var installState: InstallState { get }
    func lastCheckMessagePublisher() -> AnyPublisher<String?, Never>
    var lastCheckMessage: String? { get }
    func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never>
    var installAnywayBlockedMessage: String? { get }
    /// Classifies `error` against the currently located `polybridge-ctl`/`polybridge-setup`
    /// presence; `nil` when `error` isn't an install need.
    func installNeed(for error: ToolError) -> InstallNeed?
    /// Where the next install would land, for confirmation-dialog copy only.
    func installDestination() -> String?
    func install() async
    func installUvThenPolybridge() async
    func retry() async
    func checkAgain() async
    @discardableResult
    func installAnyway() async -> Bool
    func reset()
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
    /// The install/update banner to show where the red list error shows today, or `nil` when
    /// nothing needs surfacing (settled plan, section 5's precedence rules).
    private(set) var installBannerModel: InstallBanner.Model?

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
    @ObservationIgnored private var installState: InstallState = .idle
    @ObservationIgnored private var lastCheckMessage: String?
    @ObservationIgnored private var installAnywayBlockedMessage: String?
    @ObservationIgnored private var currentInstallNeed: InstallNeed?

    // MARK: - Init

    init(useCase: any MenuBarUseCase, routing: any MenuBarRouting) {
        self.useCase = useCase
        self.routing = routing
        self.connectionLine = useCase.connectionLine
        self.runningCount = useCase.runningCount
        self.openWindowOnStart = useCase.openWindowOnStart
        self.notifyOnFinish = useCase.notifyOnFinish
        self.installState = useCase.installState
        self.lastCheckMessage = useCase.lastCheckMessage
        self.installAnywayBlockedMessage = useCase.installAnywayBlockedMessage
        recomputeInstallBanner()
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

    // MARK: - Install banner actions (settled plan, section 5)

    func didTapInstallBannerPrimary() {
        switch installState {
        case .needsGit:
            Task { [weak self] in await self?.useCase.install() }
        case .needsUv:
            publishInstallUvDialog()
        case .failed:
            Task { [weak self] in await self?.useCase.retry() }
        case .unresolved:
            Task { [weak self] in await self?.useCase.checkAgain() }
        case .running:
            break
        case .idle, .installed:
            if let need = currentInstallNeed { publishInstallOrUpdateDialog(need: need) }
        }
    }

    func didTapInstallBannerSecondary() {
        if case .unresolved = installState { publishInstallAnywayDialog() }
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
                currentInstallNeed = error.flatMap { useCase.installNeed(for: $0) }
                listErrorMessage = currentInstallNeed == nil ? error?.message : nil
                recomputeInstallBanner()
                recompute()
            }
            .store(in: &cancellables)

        subscribeToInstallState()

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
                statusLabel: current.status.label,
                statusColor: StatusColor.of(current.status),
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

// MARK: - MenuBarVM + Install banner (settled plan, section 5)

/// Maps `InstallState`/`InstallNeed` to `InstallBanner.Model` and the three confirmation dialogs.
/// PbUI can't see `InstallState` (Core doesn't depend on UI), so this mapping lives here — a small,
/// per-feature helper duplicated in `SidebarVM`/`HarnessesVM`, not shared, per the settled plan.
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

        useCase.installAnywayBlockedMessagePublisher()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                guard let self else { return }
                installAnywayBlockedMessage = message
                recomputeInstallBanner()
            }
            .store(in: &cancellables)
    }

    private func recomputeInstallBanner() {
        switch installState {
        case .needsGit:
            installBannerModel = InstallBanner.Model(
                title: "git is needed to install polybridge",
                detail: "Install Apple's Command Line Tools first (`xcode-select --install`), then try again.",
                primaryTitle: "Try again"
            )
        case .needsUv:
            installBannerModel = InstallBanner.Model(
                title: "uv is needed to install polybridge",
                detail: "polybridge is installed with uv, which wasn't found.",
                primaryTitle: "Install uv"
            )
        case .running(let stage):
            installBannerModel = InstallBanner.Model(title: Self.runningTitle(stage), detail: Self.runningDetail(stage), isBusy: true)
        case .failed(_, let message):
            installBannerModel = InstallBanner.Model(
                title: "polybridge couldn't be installed",
                detail: "Something went wrong while installing.",
                primaryTitle: "Try again",
                errorText: message,
                canDismiss: true
            )
        case .unresolved:
            installBannerModel = InstallBanner.Model(
                title: "The install may still be running",
                detail: "It didn't finish in time and may still be working in the background. Check again once it has finished.",
                primaryTitle: "Check again",
                secondaryTitle: "Install anyway",
                errorText: installAnywayBlockedMessage ?? lastCheckMessage
            )
        case .idle, .installed:
            if let need = currentInstallNeed, let error = latestListError {
                installBannerModel = InstallBanner.Model(
                    title: need == .missing ? "polybridge isn't installed" : "polybridge is incomplete or out of date",
                    detail: error.message,
                    primaryTitle: need == .missing ? "Install polybridge" : "Update polybridge"
                )
            } else if latestListError != nil {
                // A current tool error that isn't an install need still outranks the success
                // banner (R2-2) — the plain red `listErrorMessage` shows instead, banner-free.
                installBannerModel = nil
            } else if installState == .installed {
                installBannerModel = InstallBanner.Model(
                    title: "polybridge is installed",
                    detail: "The new install passed its checks.",
                    canDismiss: true,
                    footnote: "Next: register it with your agents in Settings → Harnesses."
                )
            } else {
                installBannerModel = nil
            }
        }
    }

    private static func runningTitle(_ stage: InstallStage) -> String {
        if case .validate = stage { return "Checking…" }
        return "Installing polybridge…"
    }

    private static func runningDetail(_ stage: InstallStage) -> String {
        switch stage {
        case .git: "Checking for git…"
        case .uv: "Setting up uv…"
        case .polybridge: "Installing polybridge from GitHub. This can take a few minutes."
        case .validate: "Checking the new install. This can take a little while."
        }
    }

    private func destinationLine() -> String {
        if let destination = useCase.installDestination() { "\n\nInstalls into \(destination)." } else {
            "\n\nInstalls into uv's tool folder, once uv is found."
        }
    }

    private func publishInstallOrUpdateDialog(need: InstallNeed) {
        let isMissing = need == .missing
        let message = "This replaces the polybridge installation used by agent sessions. Existing sessions may be disrupted "
            + "or fail on later operations. Finish running tasks and close sessions using polybridge before continuing. "
            + "polybridge will be installed from GitHub with uv." + destinationLine()
        publishDialog(isMissing ? "Install polybridge?" : "Update polybridge?", description: message) {
            AlertAction(title: isMissing ? "Install" : "Update") { [weak self] in self?.confirmInstallOrUpdate() }
        }
    }

    private func publishInstallUvDialog() {
        publishDialog(
            "Install uv?",
            description: "uv is needed to install polybridge. Install it now with astral's official installer? "
                + "This downloads and runs https://astral.sh/uv/install.sh, then installs polybridge."
        ) {
            AlertAction(title: "Install uv") { [weak self] in self?.confirmInstallUv() }
        }
    }

    private func publishInstallAnywayDialog() {
        let message = "An earlier install may still be finishing. Only continue if you're sure it has stopped." + destinationLine()
        publishDialog("Install anyway?", description: message) {
            AlertAction(title: "Install anyway") { [weak self] in self?.confirmInstallAnyway() }
        }
    }

    /// Stale-confirm guard: re-checks the *current* state before acting, since the state can change
    /// between the dialog publishing and the person confirming it.
    private func confirmInstallOrUpdate() {
        guard Self.stateAllowsInstall(installState) else { return }
        Task { [weak self] in await self?.useCase.install() }
    }

    private func confirmInstallUv() {
        guard Self.stateAllowsInstallUv(installState) else { return }
        Task { [weak self] in await self?.useCase.installUvThenPolybridge() }
    }

    private func confirmInstallAnyway() {
        guard Self.stateAllowsInstallAnyway(installState) else { return }
        Task { [weak self] in await self?.useCase.installAnyway() }
    }

    private static func stateAllowsInstall(_ state: InstallState) -> Bool {
        switch state {
        case .idle, .failed, .needsGit, .needsUv, .installed: true
        case .running, .unresolved: false
        }
    }

    private static func stateAllowsInstallUv(_ state: InstallState) -> Bool {
        if case .needsUv = state { return true }
        return false
    }

    private static func stateAllowsInstallAnyway(_ state: InstallState) -> Bool {
        if case .unresolved = state { return true }
        return false
    }
}
