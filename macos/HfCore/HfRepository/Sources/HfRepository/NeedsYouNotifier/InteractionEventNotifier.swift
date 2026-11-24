import Combine
import Foundation
import MonitorCore
@preconcurrency import UserNotifications

// MARK: - InteractionNotificationLedger

/// App-owned deduplication state, isolated from engine storage and scoped to its selected state root.
actor InteractionNotificationLedger {
    private let defaults: UserDefaults
    private let key: String
    private var floor: Double
    private var seen: [String: Double]
    /// Pending identifiers whose request was already answered. A pending row arriving after its answer (a later page, a
    /// monitor flip, a retried post) must not post a banner nothing would ever remove. Absent in older ledgers.
    private var answered: [String: Double]

    init(defaults: UserDefaults, stateRoot: String, now: Double) {
        self.defaults = defaults
        self.key = "interaction-notifications.v1:" + stateRoot
        let saved = defaults.dictionary(forKey: key) ?? [:]
        let cutoff = max(saved["floor"] as? Double ?? now, now - 30 * 86400)
        self.floor = cutoff
        self.seen = (saved["seen"] as? [String: Double] ?? [:]).filter { $0.value >= cutoff }
        self.answered = (saved["answered"] as? [String: Double] ?? [:]).filter { $0.value >= cutoff }
        defaults.set(["floor": cutoff, "seen": seen, "answered": answered], forKey: key)
    }

    private func persist() {
        defaults.set(["floor": floor, "seen": seen, "answered": answered], forKey: key)
    }

    func isAnswered(_ identifier: String) -> Bool { answered[identifier] != nil }

    func recordAnswered(_ identifier: String, at timestamp: Double) {
        answered[identifier] = timestamp
        persist()
    }

    func contains(_ event: InteractionNotificationEvent) -> Bool {
        event.occurredAt < floor || seen[event.id] != nil
    }

    func record(_ event: InteractionNotificationEvent) {
        // Keep a rolling, bounded-age dedup window; older episodes are below the persisted floor.
        floor = max(floor, event.occurredAt - 30 * 86400)
        seen = seen.filter { $0.value >= floor }
        answered = answered.filter { $0.value >= floor }
        seen[event.id] = event.occurredAt
        persist()
    }
}

// MARK: - InteractionEventNotifier

/// Polls durable engine episodes and posts individual macOS notifications, including between-poll events.
final class InteractionEventNotifier: NeedsYouNotifier, @unchecked Sendable {
    private let tooling: any ToolEnvironmentRepository
    private let install: any InstallRepository
    private let settings: any SettingsRepository
    private let scheduler: any Scheduling
    private let center: any NotificationCentering
    private let canNotify: @Sendable () -> Bool
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    // Not guarded by `lock`: subscribers run synchronously on `send`, so it is only ever sent to outside any lock.
    private let availability = CurrentValueSubject<NotificationFeedAvailability, Never>(.unknown)

    init(tooling: any ToolEnvironmentRepository, install: any InstallRepository, settings: any SettingsRepository,
         scheduler: any Scheduling, center: any NotificationCentering, defaults: UserDefaults = .standard,
         canNotify: @escaping @Sendable () -> Bool = { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }) {
        self.canNotify = canNotify
        self.defaults = defaults
        self.tooling = tooling
        self.install = install
        self.settings = settings
        self.scheduler = scheduler
        self.center = center
    }

    var feedAvailability: NotificationFeedAvailability { availability.value }

    func feedAvailabilityPublisher() -> AnyPublisher<NotificationFeedAvailability, Never> {
        availability.removeDuplicates().eraseToAnyPublisher()
    }

    func permission() async -> NotificationAuthorization? {
        guard canNotify() else { return nil }
        return await center.authorizationStatus()
    }

    private func publish(_ value: NotificationFeedAvailability) {
        if availability.value != value { availability.send(value) }
    }

    func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task { [weak self] in await self?.poll() }
        }
    }

    private func poll() async {
        var cursor: String?
        var root: String?
        var ledger: InteractionNotificationLedger?
        while !Task.isCancelled {
            if install.setupState.isReady, let client = try? tooling.ctl().get() {
                let selected = client.compatibilityContext.expectedStateRoot
                if root != selected {
                    root = selected
                    cursor = nil
                    publish(.unknown)
                    ledger = InteractionNotificationLedger(defaults: defaults, stateRoot: selected, now: scheduler.now().timeIntervalSince1970)
                }
                let result = await client.interactionEvents(cursor: cursor)
                guard current(client) else { continue }
                switch result {
                case .success(let page):
                    publish(.available)
                    if let ledger {
                        guard await process(page, ledger: ledger, client: client) else { return }
                    }
                    cursor = page.cycleComplete ? nil : page.nextCursor
                    // Drain a cycle promptly without an unbounded burst of subprocesses.
                    try? await scheduler.wait(for: page.cycleComplete ? 3 : 0.25)
                    continue
                case .failure(let error):
                    if case .unsupportedCommand = error { publish(.unavailable) }
                    // Failed pages retain their cursor; malformed sources must not silently advance it. An engine
                    // without the interaction-events capability (`.unsupportedCommand`) posts nothing; the loop
                    // keeps its 3 s cadence, so it recovers if the selected runtime later gains the capability.
                }
            }
            try? await scheduler.wait(for: 3)
        }
    }

    /// Returns false when the task was cancelled part-way.
    private func process(_ page: InteractionEventPage, ledger: InteractionNotificationLedger, client: CtlClient) async -> Bool {
        let answered = Set(page.events.filter { $0.state == "answered" }.compactMap(Self.pendingIdentifier))
        for event in page.events {
            guard !Task.isCancelled else { return false }
            if await ledger.contains(event) { continue }
            if event.state == "pending", let id = Self.pendingIdentifier(event) {
                let alreadyAnswered = await ledger.isAnswered(id)
                if answered.contains(id) || alreadyAnswered {
                    if current(client) { await ledger.record(event) }
                    continue
                }
            }
            if await deliver(event, isCurrent: { [self] in current(client) }), current(client) {
                if event.state == "answered", let id = Self.pendingIdentifier(event) { await ledger.recordAnswered(id, at: event.occurredAt) }
                await ledger.record(event)
            }
        }
        return true
    }

    private func current(_ client: CtlClient) -> Bool {
        guard !Task.isCancelled, install.setupState.isReady, let selected = try? tooling.ctl().get() else { return false }
        return selected.executable == client.executable && selected.compatibilityContext == client.compatibilityContext
    }

    func deliver(_ event: InteractionNotificationEvent, isCurrent: @Sendable () -> Bool) async -> Bool {
        guard isCurrent() else { return false }
        if event.state == "answered" {
            // Removal ignores the two switches: a banner already on screen must go once its request is answered.
            guard canNotify() else { return true }
            if let id = Self.pendingIdentifier(event) {
                center.removeDelivered(identifiers: [id])
                center.removePending(identifiers: [id])
            }
            return true
        }
        if event.state == "pending", !event.monitorAvailable { return false }
        let terminal = event.kind == "task"
        guard terminal ? settings.notifyOnFinish : settings.notifyOnNeedsYou else { return true }
        guard canNotify() else { return true }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return isCurrent() }
            guard isCurrent(), terminal ? settings.notifyOnFinish : settings.notifyOnNeedsYou else { return false }
            let content = Self.content(event)
            try await center.add(UNNotificationRequest(identifier: Self.identifier(event), content: content, trigger: nil))
            return true
        } catch { return false }
    }

    /// The identifier a request's pending and answered rows share, so an answer finds the banner to remove.
    /// Nil for task rows and for engines that send no `interaction_id`.
    static func pendingIdentifier(_ event: InteractionNotificationEvent) -> String? {
        guard event.kind != "task", let interaction = event.interactionID else { return nil }
        let key = [event.workflowRunID, event.sourceWorkflowRunID, event.taskID, interaction].map { $0 ?? "" }
        return "interaction:" + key.joined(separator: "|")
    }

    static func identifier(_ event: InteractionNotificationEvent) -> String {
        pendingIdentifier(event) ?? "interaction-" + event.id
    }

    static func content(_ event: InteractionNotificationEvent) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if event.kind == "task" {
            content.title = (event.state == "completed" ? "Done: " : "Failed: ") + event.title
        } else {
            let label = event.kind == "approval" ? "Approval" : event.kind == "question" ? "Question" : "Recovery"
            content.title = label + ": " + event.title
        }
        content.body = String(event.body.prefix(512))
        content.threadIdentifier = "harflow-interactions"
        if event.kind == "task" {
            if let task = event.taskID {
                content.userInfo = ["task_id": task]
            } else if let run = event.workflowRunID {
                content.userInfo = ["workflow_run_id": run]
            }
        } else {
            var info: [String: String] = ["needs_you_kind": event.kind]
            info["workflow_run_id"] = event.workflowRunID
            info["task_id"] = event.taskID
            info["interaction_id"] = event.interactionID
            content.userInfo = info
        }
        return content
    }
}
