import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - TaskStatusLabelTests

/// The running badge must omit elapsed time when the listing has no start time or duration.
/// `Format.clock(nil)` is intentionally a displayable placeholder for other callers, but it is
/// not truthful here: this view must not claim that a missing clock is `--:--`.
@MainActor @Suite(.serialized) struct TaskStatusLabelTests {
    @Test func givenRunningTaskWithoutStartOrDuration_whenHosted_thenBadgeOmitsUnavailableClock() async throws {
        // given — a lenient list response with no timing fields at all.
        let previousEnhanced = enableAccessibility()
        defer { restoreAccessibility(previousEnhanced) }
        let task = try #require(makeTask(status: "running"))
        let host = host(task: task)
        defer { close(host.window) }

        // when
        await waitUntil(timeout: 5) {
            host.host.layoutSubtreeIfNeeded()
            return accessibilityLabels(in: host.host).contains("Running")
        }

        // then — the actual production badge's single AX element contains only the truthful state.
        let labels = accessibilityLabels(in: host.host)
        #expect(labels.contains("Running"))
        #expect(!labels.contains { $0.contains("--:--") })
    }

    @Test func givenRunningTaskWithStartTime_whenHosted_thenBadgeReportsItsAvailableElapsedTime() async throws {
        // given — a live task started 65 seconds ago, with no fabricated duration field.
        let previousEnhanced = enableAccessibility()
        defer { restoreAccessibility(previousEnhanced) }
        let startedAt = Date().addingTimeInterval(-65)
        let task = try #require(makeTask(status: "running", startedAt: ISO8601DateFormatter().string(from: startedAt)))
        let host = host(task: task)
        defer { close(host.window) }

        // when
        await waitUntil(timeout: 5) {
            host.host.layoutSubtreeIfNeeded()
            return accessibilityLabels(in: host.host).contains(where: { $0.hasPrefix("Running, ") })
        }

        // then — the live clock is present and is a real formatted duration, not the unavailable
        // placeholder. Compare against the observation window so a slow hosted frame does not
        // make this test depend on an arbitrary fixed duration.
        let label = try #require(accessibilityLabels(in: host.host).first(where: { $0.hasPrefix("Running, ") }))
        let observed = try #require(label.split(separator: ",", maxSplits: 1).last.map(String.init))
        let seconds = try #require(clockSeconds(observed))
        let now = Date()
        let lowerBound = Int(now.timeIntervalSince(startedAt).rounded(.down)) - 1
        let upperBound = Int(now.timeIntervalSince(startedAt).rounded(.down)) + 1
        #expect((lowerBound ... upperBound).contains(seconds))
        #expect(!label.contains("--:--"))
    }

    private struct HostedBadge {
        let host: NSView
        let window: NSWindow
    }

    private func host(task: TaskInfo) -> HostedBadge {
        _ = NSApplication.shared
        let controller = NSHostingController(rootView: AnyView(TaskStatusLabel(task: task).frame(width: 240, height: 40)))
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        return HostedBadge(host: controller.view, window: window)
    }

    private func close(_ window: NSWindow) {
        window.contentView = nil
        window.close()
    }

    private func enableAccessibility() -> Any? {
        let attribute = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApplication.shared.accessibilityAttributeValue(attribute)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: attribute)
        return previous
    }

    private func restoreAccessibility(_ value: Any?) {
        NSApplication.shared.accessibilitySetValue(value, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }

    private func makeTask(status: String, startedAt: String? = nil) -> TaskInfo? {
        var raw: [String: JSONValue] = [
            "task_id": .string("status-label-test"), "backend": .string("claude"), "status": .string(status)
        ]
        if let startedAt { raw["started_at"] = .string(startedAt) }
        return TaskInfo(.object(raw))
    }

    private func clockSeconds(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        switch parts.count {
        case 2: return parts[0]! * 60 + parts[1]!
        case 3: return parts[0]! * 3600 + parts[1]! * 60 + parts[2]!
        default: return nil
        }
    }

    private func accessibilityLabels(in root: NSView) -> [String] {
        var labels = Set<String>()
        for view in [root] + root.subviews.flatMap(descendants) {
            for object in accessibilityTree(view) {
                if let label = value(object, key: "accessibilityLabel") { labels.insert(label) }
            }
        }
        return Array(labels)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func accessibilityTree(_ object: NSObject) -> [NSObject] {
        var result = [object]
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return result }
        for child in children {
            if let child = child as? NSObject { result += accessibilityTree(child) }
        }
        return result
    }

    private func value(_ object: NSObject, key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}
