import Combine
import Foundation
import MonitorCore
@preconcurrency import UserNotifications

// MARK: - NeedsYouNotifierImpl

public final class NeedsYouNotifierImpl: NeedsYouNotifier, @unchecked Sendable {
    static let summaryThreshold = 3
    static let summaryIdentifier = "needs-you-summary"
    static let coalesceSeconds: TimeInterval = 0.5

    private let repository: any NeedsYouRepository
    private let settings: any SettingsRepository
    private let center: any NotificationCentering
    private let scheduler: any Scheduling
    private let bundleIdentifier: @Sendable () -> String?
    private let isAppBundle: @Sendable () -> Bool

    private let lock = NSLock()
    private var subscription: AnyCancellable?
    private var batch: [NeedsYouItem] = []
    private var flushToken: AnyCancellable?
    private var summaryMembers: Set<String> = []

    /// `bundleIdentifier`/`isAppBundle` mirror `FinishNotifierImpl`: injectable so tests can exercise the real-app branch.
    public init(
        repository: any NeedsYouRepository,
        settings: any SettingsRepository,
        center: any NotificationCentering = SystemNotificationCenter(),
        scheduler: any Scheduling,
        bundleIdentifier: @escaping @Sendable () -> String? = { Bundle.main.bundleIdentifier },
        isAppBundle: @escaping @Sendable () -> Bool = { Bundle.main.bundleURL.pathExtension == "app" }
    ) {
        self.repository = repository
        self.settings = settings
        self.center = center
        self.scheduler = scheduler
        self.bundleIdentifier = bundleIdentifier
        self.isAppBundle = isAppBundle
    }

    private var canNotify: Bool { bundleIdentifier() != nil && isAppBundle() }

    public func start() {
        lock.lock()
        defer { lock.unlock() }
        guard subscription == nil else { return }
        subscription = repository.eventsPublisher().sink { [weak self] event in self?.handle(event) }
    }

    private func handle(_ event: NeedsYouEvent) {
        switch event {
        case .appeared(let item, let sourceBaseline):
            guard !sourceBaseline else { return }
            lock.lock()
            batch.append(item)
            let needsFlush = flushToken == nil
            lock.unlock()
            if needsFlush { scheduleFlush() }
        case .resolved(let id):
            resolve(id)
        }
    }

    private func scheduleFlush() {
        let token = scheduler.schedule(after: Self.coalesceSeconds) { [weak self] in self?.flush() }
        lock.lock()
        flushToken = token
        lock.unlock()
    }

    private func resolve(_ id: String) {
        lock.lock()
        batch.removeAll { $0.id == id }
        var identifiers = [Self.identifier(id)]
        if summaryMembers.remove(id) != nil, summaryMembers.isEmpty { identifiers.append(Self.summaryIdentifier) }
        lock.unlock()
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    /// Delivers everything that appeared since the last flush. Exposed to tests through the scheduler.
    func flush() {
        lock.lock()
        let items = batch
        batch = []
        flushToken = nil
        lock.unlock()
        guard !items.isEmpty, settings.notifyOnNeedsYou, canNotify else { return }
        Task { await deliver(items) }
    }

    private func deliver(_ items: [NeedsYouItem]) async {
        guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]), granted else { return }
        if items.count > Self.summaryThreshold {
            let content = UNMutableNotificationContent()
            content.title = "\(items.count) requests need you"
            content.body = items.prefix(3).map(\.runTitle).joined(separator: ", ")
            content.threadIdentifier = "needs-you"
            content.userInfo = ["needs_you_list": "1"]
            lock.withLock { summaryMembers.formUnion(items.map(\.id)) }
            try? await center.add(UNNotificationRequest(identifier: Self.summaryIdentifier, content: content, trigger: nil))
            return
        }
        for item in items {
            let content = UNMutableNotificationContent()
            content.title = "\(Self.label(item.kind)): \(item.runTitle)"
            if item.ownership.callerEnded { content.subtitle = "The caller ended. You can answer now." }
            content.body = item.firstLine
            content.threadIdentifier = "needs-you"
            content.userInfo = ["needs_you_item": item.id]
            try? await center.add(UNNotificationRequest(identifier: Self.identifier(item.id), content: content, trigger: nil))
        }
    }

    static func identifier(_ id: String) -> String { "needs-you-\(id)" }

    static func label(_ kind: NeedsYouItem.Kind) -> String {
        switch kind {
        case .approval: "Approval"
        case .question: "Question"
        case .recovery: "Recovery"
        }
    }
}
