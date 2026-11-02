import Foundation
import MonitorCore
@preconcurrency import UserNotifications

// MARK: - NotificationDeliveryMode

/// Shared routing gate prevents the legacy listing and durable feed from posting the same event.
final class NotificationDeliveryMode: @unchecked Sendable {
    private let lock = NSLock()
    private var legacy = false
    var allowsLegacy: Bool { lock.withLock { legacy } }
    func setLegacy(_ value: Bool) { lock.withLock { legacy = value } }
}

// MARK: - InteractionNotificationLedger

/// App-owned deduplication state, isolated from engine storage and scoped to its selected state root.
actor InteractionNotificationLedger {
    private let defaults: UserDefaults
    private let key: String
    private var floor: Double
    private var seen: [String: Double]

    init(defaults: UserDefaults, stateRoot: String, now: Double) {
        self.defaults = defaults
        self.key = "interaction-notifications.v1:" + stateRoot
        let saved = defaults.dictionary(forKey: key) ?? [:]
        let cutoff = max(saved["floor"] as? Double ?? now, now - 30 * 86400)
        self.floor = cutoff
        self.seen = (saved["seen"] as? [String: Double] ?? [:]).filter { $0.value >= cutoff }
        defaults.set(["floor": cutoff, "seen": seen], forKey: key)
    }

    func contains(_ event: InteractionNotificationEvent) -> Bool {
        event.occurredAt < floor || seen[event.id] != nil
    }

    func record(_ event: InteractionNotificationEvent) {
        // Keep a rolling, bounded-age dedup window; older episodes are below the persisted floor.
        floor = max(floor, event.occurredAt - 30 * 86400)
        seen = seen.filter { $0.value >= floor }
        seen[event.id] = event.occurredAt
        defaults.set(["floor": floor, "seen": seen], forKey: key)
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
    private let legacy: any NeedsYouNotifier
    private let mode: NotificationDeliveryMode
    private let canNotify: @Sendable () -> Bool
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(tooling: any ToolEnvironmentRepository, install: any InstallRepository, settings: any SettingsRepository,
         scheduler: any Scheduling, center: any NotificationCentering, legacy: any NeedsYouNotifier, mode: NotificationDeliveryMode,
         canNotify: @escaping @Sendable () -> Bool = { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }) {
        self.canNotify = canNotify
        self.tooling = tooling
        self.install = install
        self.settings = settings
        self.scheduler = scheduler
        self.center = center
        self.legacy = legacy
        self.mode = mode
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
                    ledger = InteractionNotificationLedger(defaults: .standard, stateRoot: selected, now: scheduler.now().timeIntervalSince1970)
                }
                let result = await client.interactionEvents(cursor: cursor)
                guard current(client) else { continue }
                switch result {
                case .success(let page):
                    mode.setLegacy(false)
                    if let ledger {
                        for event in page.events {
                            guard !Task.isCancelled else { return }
                            if await ledger.contains(event) { continue }
                            if await deliver(event, isCurrent: { [self] in current(client) }), current(client) { await ledger.record(event) }
                        }
                    }
                    cursor = page.cycleComplete ? nil : page.nextCursor
                    // Drain a cycle promptly without an unbounded burst of subprocesses.
                    try? await scheduler.wait(for: page.cycleComplete ? 3 : 0.25)
                    continue
                case .failure(let error):
                    if case .unsupportedCommand = error {
                        mode.setLegacy(true)
                        legacy.start()
                    }
                    // Failed pages retain their cursor; malformed sources must not silently advance it.
                }
            }
            try? await scheduler.wait(for: 3)
        }
    }

    private func current(_ client: CtlClient) -> Bool {
        guard !Task.isCancelled, install.setupState.isReady, let selected = try? tooling.ctl().get() else { return false }
        return selected.executable == client.executable && selected.compatibilityContext == client.compatibilityContext
    }

    func deliver(_ event: InteractionNotificationEvent, isCurrent: @Sendable () -> Bool) async -> Bool {
        guard isCurrent() else { return false }
        if event.state == "pending", !event.monitorAvailable { return false }
        let terminal = event.kind == "task"
        guard terminal ? settings.notifyOnFinish : settings.notifyOnNeedsYou else { return true }
        guard canNotify() else { return true }
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return isCurrent() }
            guard isCurrent(), terminal ? settings.notifyOnFinish : settings.notifyOnNeedsYou else { return false }
            let content = Self.content(event)
            try await center.add(UNNotificationRequest(identifier: "interaction-" + event.id, content: content, trigger: nil))
            return true
        } catch { return false }
    }

    static func content(_ event: InteractionNotificationEvent) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        if event.state == "answered" {
            content.title = event.answeredBy == "monitor" ? "Answered in Harflow" : "Answered by the caller"
            content.subtitle = event.title
        } else if event.kind == "task" {
            content.title = (event.state == "completed" ? "Done: " : "Failed: ") + event.title
        } else {
            let label = event.kind == "approval" ? "Approval" : event.kind == "question" ? "Question" : "Recovery"
            content.title = label + ": " + event.title
        }
        content.body = String(event.body.prefix(512))
        content.threadIdentifier = "harflow-interactions"
        if let run = event.workflowRunID {
            content.userInfo = ["workflow_run_id": run]
        } else if let task = event.taskID {
            content.userInfo = ["task_id": task]
        }
        return content
    }
}
