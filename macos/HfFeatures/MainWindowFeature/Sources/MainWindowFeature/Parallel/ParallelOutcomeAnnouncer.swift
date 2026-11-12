//
//  ParallelOutcomeAnnouncer.swift
//  MainWindowFeature
//
//  A lane announces its outcome line when it first appears or changes. One action can set the same outcome on several
//  lanes at once (Cancel all), so announcements within a short burst are coalesced into one.
//

import AppKit

// MARK: - OutcomeAnnouncementCoalescer

/// The burst's pure logic: unique texts in arrival order, flushed as one announcement.
struct OutcomeAnnouncementCoalescer: Equatable {
    private(set) var texts: [String] = []

    var isEmpty: Bool { texts.isEmpty }

    mutating func add(_ text: String) {
        if !texts.contains(text) { texts.append(text) }
    }

    /// The single announcement for the burst, or `nil` when nothing was added; clears the burst.
    mutating func flush() -> String? {
        defer { texts = [] }
        return texts.isEmpty ? nil : texts.joined(separator: " ")
    }
}

// MARK: - ParallelOutcomeAnnouncer

@MainActor
enum ParallelOutcomeAnnouncer {
    /// How long a burst collects before it is announced.
    static let window: Duration = .milliseconds(250)
    private static var coalescer = OutcomeAnnouncementCoalescer()
    private static var pending: Task<Void, Never>?
    /// Replaced by tests to observe what would be posted.
    static var post: (String) -> Void = { text in
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    static func announce(_ text: String) {
        coalescer.add(text)
        guard pending == nil else { return }
        pending = Task { @MainActor in
            try? await Task.sleep(for: window)
            pending = nil
            if let message = coalescer.flush() { post(message) }
        }
    }
}
