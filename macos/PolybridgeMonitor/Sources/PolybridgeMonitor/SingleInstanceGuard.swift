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
    var launchDate: Date?
}

extension RunningAppSnapshot {
    /// Snapshots a real `NSRunningApplication` — the only place this type touches AppKit.
    init(runningApplication app: NSRunningApplication) {
        self.init(
            bundleIdentifier: app.bundleIdentifier,
            bundleURL: app.bundleURL,
            isTerminated: app.isTerminated,
            processIdentifier: app.processIdentifier,
            launchDate: app.launchDate
        )
    }
}

// MARK: - SingleInstanceGuard

/// Elects the oldest matching app at another bundle path. Equal or unavailable launch dates use
/// PID as a deterministic tie break; known dates precede unknown ones. Every concurrent copy uses
/// the same ordering, so two launches cannot each defer to the other and both quit.
enum SingleInstanceGuard {
    static func findDuplicate(
        among runningApps: [RunningAppSnapshot],
        selfBundleIdentifier: String?,
        selfBundleURL: URL?,
        selfProcessIdentifier: pid_t,
        selfLaunchDate: Date? = nil
    ) -> RunningAppSnapshot? {
        guard let selfBundleIdentifier, let normalizedSelfURL = normalize(selfBundleURL) else { return nil }
        let own = RunningAppSnapshot(
            bundleIdentifier: selfBundleIdentifier, bundleURL: normalizedSelfURL,
            isTerminated: false, processIdentifier: selfProcessIdentifier, launchDate: selfLaunchDate
        )
        let candidates = runningApps.filter { candidate in
            guard !candidate.isTerminated else { return false }
            guard candidate.processIdentifier != selfProcessIdentifier else { return false }
            guard candidate.bundleIdentifier == selfBundleIdentifier else { return false }
            guard let candidateURL = normalize(candidate.bundleURL) else { return false }
            return candidateURL != normalizedSelfURL && precedes(candidate, own)
        }
        return candidates.min(by: precedes)
    }

    private static func precedes(_ lhs: RunningAppSnapshot, _ rhs: RunningAppSnapshot) -> Bool {
        switch (lhs.launchDate, rhs.launchDate) {
        case let (left?, right?) where left != right: left < right
        case (_?, nil): true
        case (nil, _?): false
        default: lhs.processIdentifier < rhs.processIdentifier
        }
    }

    private static func normalize(_ url: URL?) -> URL? {
        url?.standardizedFileURL.resolvingSymlinksInPath()
    }
}
