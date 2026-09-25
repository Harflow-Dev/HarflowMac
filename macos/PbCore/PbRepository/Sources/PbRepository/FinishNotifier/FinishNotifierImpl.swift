import Foundation
import MonitorCore
@preconcurrency import UserNotifications

// MARK: - FinishNotifierImpl

public final class FinishNotifierImpl: FinishNotifier, @unchecked Sendable {

    private let settings: any SettingsRepository
    private let center: any NotificationCentering
    private let bundleIdentifier: @Sendable () -> String?
    private let isAppBundle: @Sendable () -> Bool

    /// `bundleIdentifier`/`isAppBundle` default to the real `Bundle.main` check
    /// (`AppModel.canNotify`, `AppModel.swift:456`) but are injectable, so a test can exercise the
    /// "running as a real .app" branch without one — the default test-host bundle is never a `.app`.
    public init(
        settings: any SettingsRepository,
        center: any NotificationCentering = SystemNotificationCenter(),
        bundleIdentifier: @escaping @Sendable () -> String? = { Bundle.main.bundleIdentifier },
        isAppBundle: @escaping @Sendable () -> Bool = { Bundle.main.bundleURL.pathExtension == "app" }
    ) {
        self.settings = settings
        self.center = center
        self.bundleIdentifier = bundleIdentifier
        self.isAppBundle = isAppBundle
    }

    private var canNotify: Bool { bundleIdentifier() != nil && isAppBundle() }

    public func notify(_ finished: [TaskInfo], titleFor: @escaping @Sendable (String) -> String) {
        guard settings.notifyOnFinish, canNotify, !finished.isEmpty else { return }
        Task {
            guard let granted = try? await center.requestAuthorization(options: [.alert, .sound]), granted else { return }
            for task in finished {
                let content = UNMutableNotificationContent()
                content.title = "\(task.status.label): \(titleFor(task.taskID))"
                content.body = "\(task.backend) · \(RepoPathFormat.repo(task.repoPath))"
                content.userInfo = ["task_id": task.taskID]
                try? await center.add(UNNotificationRequest(identifier: "finished-\(task.taskID)", content: content, trigger: nil))
            }
        }
    }
}
