//
//  ParallelTopBarContent.swift
//  MainWindowFeature
//
//  What a Parallel group publishes to the window's top bar: the group's name, one badge counting its current
//  members, and one enforcement sentence. Every field is quantised, so an unchanged recompute writes nothing.
//  Design reference: HarflowDesign 4ff7d83, `states-parallel-lanes.js` `topbar`.
//

import Foundation
import MonitorCore

// MARK: - GroupTopBarContent

/// The principal item's content for one Parallel group.
struct GroupTopBarContent: Equatable, Sendable {
    let title: String
    /// "1 running · 2 done"; `nil` for an empty group and while loading.
    let badge: TaskBadgeModel?
    /// The enforcement sentence; `nil` for an empty group and while loading.
    let meta: String?
    /// The group's membership is not known yet: the bar draws its skeleton blocks.
    var isLoading = false
}

// MARK: - ParallelStatusCounts

/// The current member of every conversation counted in exactly one bucket, in the badge's native order: running,
/// done, failed (timed out included) and cancelled. An unknown status is counted nowhere.
struct ParallelStatusCounts: Equatable, Sendable {
    var running = 0
    var done = 0
    var failed = 0
    var cancelled = 0

    nonisolated init(tasks: [TaskInfo]) {
        for task in tasks {
            switch task.status {
            case .running: running += 1
            case .completed: done += 1
            case .failed, .timedOut: failed += 1
            case .cancelled: cancelled += 1
            case .other: break
            }
        }
    }

    var isEmpty: Bool { running + done + failed + cancelled == 0 }

    /// "1 running · 2 done · 1 failed · 1 cancelled", omitting zero buckets; `nil` when nothing can be counted.
    var text: String? {
        var parts: [String] = []
        if running > 0 { parts.append("\(running) running") }
        if done > 0 { parts.append("\(done) done") }
        if failed > 0 { parts.append("\(failed) failed") }
        if cancelled > 0 { parts.append("\(cancelled) cancelled") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - TaskBadgeModel group badge

extension TaskBadgeModel {
    /// The group's badge: running when anything runs (spinner), else failed, then neutral for a cancelled one, else
    /// done. Non-running badges carry no icon. `nil` when there is nothing to count.
    nonisolated static func group(_ counts: ParallelStatusCounts) -> TaskBadgeModel? {
        guard let text = counts.text else { return nil }
        let icon: Icon = counts.running > 0 ? .spinner : .none
        let tone: Tone = if counts.running > 0 { .running } else if counts.failed > 0 { .failed } else if counts.cancelled > 0 { .neutral } else { .done }
        return TaskBadgeModel(icon: icon, tone: tone, label: text, clock: .none, suffix: nil)
    }
}
