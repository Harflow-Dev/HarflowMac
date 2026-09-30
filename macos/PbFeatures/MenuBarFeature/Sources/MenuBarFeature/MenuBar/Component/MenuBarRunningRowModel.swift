//
//  MenuBarRunningRowModel.swift
//  MenuBarFeature
//
//  Feature-local component model: only the menu bar's running-tasks list needs this exact shape
//  (a live clock plus a current-tool/last-assistant-text activity line), so it stays here rather
//  than in PbUI (contrast `PbUI.TaskRowModel`, which IS shared with Sidebar).
//

import Foundation

/// Presentation data for one running-task row. `activityLine`/`activityIsMonospaced` come from the
/// task's live event stream (decision 6 lease); `startedAt`/`durationSeconds` drive the view's own
/// `TimelineView` clock so the VM does not need to republish once a second.
struct MenuBarRunningRowModel: Identifiable, Equatable {
    let id: String
    let backend: String
    let title: String
    /// The repository's name (`Format.repoName`), the second part of the activity line.
    let repoName: String
    let startedAt: Date?
    let durationSeconds: Double?
    let activityLine: String?
    let activityIsMonospaced: Bool
}
