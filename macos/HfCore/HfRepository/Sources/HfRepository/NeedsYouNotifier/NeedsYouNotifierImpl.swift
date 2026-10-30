import Combine
import Foundation
import MonitorCore
@preconcurrency import UserNotifications

// MARK: - NeedsYouNotifierImpl

public final class NeedsYouNotifierImpl: NeedsYouNotifier, @unchecked Sendable {
    static let summaryThreshold = 3
    static let categoryIdentifier = "needs-you"
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
    /// Requests that appeared and are not resolved. Delivery re-checks it immediately before posting.
    private var live: Set<String> = []
    private var summaryMembers: Set<String> = []
    private var tail: Task<Void, Never>?

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
            live.insert(item.id)
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

    /// Delivery and removal run on one serial chain, so a removal can never overtake the post it belongs to.
    private func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await operation()
        }
        lock.unlock()
    }

    private func resolve(_ id: String) {
        lock.lock()
        live.remove(id)
        batch.removeAll { $0.id == id }
        let wasMember = summaryMembers.remove(id) != nil
        lock.unlock()
        enqueue { [self] in
            var identifiers = [Self.identifier(id)]
            let clearSummary = lock.withLock { wasMember && summaryMembers.isEmpty }
            if clearSummary { identifiers.append(Self.summaryIdentifier) }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    /// Delivers everything that appeared since the last flush. Exposed to tests through the scheduler.
    func flush() {
        lock.lock()
        let items = batch
        batch = []
        flushToken = nil
        lock.unlock()
        guard !items.isEmpty, settings.notifyOnNeedsYou, canNotify else { return }
        enqueue { [self] in await deliver(items) }
    }

    private func unresolved(_ items: [NeedsYouItem]) -> [NeedsYouItem] {
        lock.withLock { items.filter { live.contains($0.id) } }
    }

    private func deliver(_ items: [NeedsYouItem]) async {
        guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]), granted else { return }
        await center.registerCategory(UNNotificationCategory(
            identifier: Self.categoryIdentifier, actions: [], intentIdentifiers: [],
            hiddenPreviewsBodyPlaceholder: "A request needs you", options: []
        ))
        // Resolution may have arrived during either suspension above: post only what is still unresolved.
        let remaining = unresolved(items)
        guard !remaining.isEmpty else { return }
        if remaining.count > Self.summaryThreshold {
            let content = UNMutableNotificationContent()
            content.title = "\(remaining.count) requests need you"
            content.body = remaining.prefix(3).map(\.runTitle).joined(separator: ", ")
            content.threadIdentifier = "needs-you"
            content.categoryIdentifier = Self.categoryIdentifier
            content.userInfo = ["needs_you_list": "1"]
            // Membership is taken together with the live check, so a request resolved a moment ago never joins.
            let members = lock.withLock { () -> Set<String> in
                let stillLive = Set(remaining.map(\.id)).intersection(live)
                summaryMembers.formUnion(stillLive)
                return stillLive
            }
            guard !members.isEmpty else { return }
            try? await center.add(UNNotificationRequest(identifier: Self.summaryIdentifier, content: content, trigger: nil))
            // Members resolved while the post was in flight: their removals were queued behind this operation
            // but may have seen a non-empty set, so reconcile once the post has landed.
            if lock.withLock({ summaryMembers.isEmpty }) {
                center.removeDeliveredNotifications(withIdentifiers: [Self.summaryIdentifier])
            }
            return
        }
        for item in remaining {
            guard unresolved([item]).count == 1 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "\(Self.label(item.kind)): \(item.runTitle)"
            if item.ownership.callerEnded { content.subtitle = "The caller ended. You can answer now." }
            // An approval's action input (a command, a path) is never shown in a notification, which can be
            // visible on a locked screen; only the tool is named. Questions and recoveries show their first line.
            content.body = item.kind == .approval ? Self.approvalBody(item) : item.firstLine
            content.categoryIdentifier = Self.categoryIdentifier
            content.threadIdentifier = "needs-you"
            content.userInfo = ["needs_you_item": item.id]
            try? await center.add(UNNotificationRequest(identifier: Self.identifier(item.id), content: content, trigger: nil))
        }
    }

    static func approvalBody(_ item: NeedsYouItem) -> String {
        let action = item.approval?.raw["action"]?.objectValue
        let tool = action?["tool_name"]?.stringValue ?? item.approval?.text("tool_name") ?? ""
        return tool.isEmpty ? "Approval requested" : "\(tool) approval requested"
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
