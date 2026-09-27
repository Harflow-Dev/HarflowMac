//
//  SingleInstanceGuard.swift
//  PolybridgeMonitor
//
//  Pure duplicate-instance detection (Monitor piece 9 — settled plan
//  `.claude/plans/2026-09-27-monitor-p9-single-instance.md`): a value-snapshot rule over running
//  applications, decoupled from `NSRunningApplication` so it is testable without any real running
//  app. `AppDelegate.applicationWillFinishLaunching` is the only caller.
//

import AppKit
import Foundation

// MARK: - RunningAppSnapshot

/// A value snapshot of one running application — only the fields `SingleInstanceGuard` needs.
struct RunningAppSnapshot: Equatable {
    let bundleIdentifier: String?
    let bundleURL: URL?
    let isTerminated: Bool
    let processIdentifier: pid_t
}

extension RunningAppSnapshot {
    /// Snapshots a real `NSRunningApplication` — the only place this type touches AppKit.
    init(runningApplication app: NSRunningApplication) {
        self.init(
            bundleIdentifier: app.bundleIdentifier,
            bundleURL: app.bundleURL,
            isTerminated: app.isTerminated,
            processIdentifier: app.processIdentifier
        )
    }
}

// MARK: - SingleInstanceGuard

/// Best-effort duplicate detection: a duplicate is another **non-terminated** process with this
/// app's own bundle identifier, running from a **different** bundle path. A terminated match, a
/// match with a different bundle identifier, a match at the exact same bundle path (macOS never
/// launches a second process from one bundle path), or this process's own entry are never
/// duplicates. Deliberately conservative when either side's path is unknown: with nothing to
/// compare, a mismatch is not asserted.
enum SingleInstanceGuard {
    static func findDuplicate(
        among runningApps: [RunningAppSnapshot],
        selfBundleIdentifier: String?,
        selfBundleURL: URL?,
        selfProcessIdentifier: pid_t
    ) -> RunningAppSnapshot? {
        guard let selfBundleIdentifier, let normalizedSelfURL = normalize(selfBundleURL) else { return nil }
        return runningApps.first { candidate in
            guard !candidate.isTerminated else { return false }
            guard candidate.processIdentifier != selfProcessIdentifier else { return false }
            guard candidate.bundleIdentifier == selfBundleIdentifier else { return false }
            guard let candidateURL = normalize(candidate.bundleURL) else { return false }
            return candidateURL != normalizedSelfURL
        }
    }

    private static func normalize(_ url: URL?) -> URL? {
        url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}
