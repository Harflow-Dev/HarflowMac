//
//  TaskTopBarContent.swift
//  MainWindowFeature
//
//  What a standalone task publishes to the window's top bar. Every field is quantised: nothing that changes
//  without changing what is drawn (usage, event counts, metadata) takes part, so an unchanged recompute writes
//  nothing. Time-derived pieces (the running clock) are drawn by child views, not carried as values here.
//

import Foundation
import HfUI
import MonitorCore

// MARK: - TaskTopBarContent

/// The principal item's content for one standalone task.
struct TaskTopBarContent: Equatable, Sendable {
    let title: String
    let badge: TaskBadgeModel
    /// Backend and model, repository and turns, in drawing order.
    let metaParts: [String]
    /// A task action is in flight; a small spinner sits in a reserved slot beside the badge.
    let isBusy: Bool
    let isPending: Bool
    /// Whether the right pane is open.
    let paneOpen: Bool
    let showsContinuity: Bool
    let noticeCount: Int
    /// The access chip's text, `nil` when the task has no `freedom` or is pending.
    let accessText: String?
    /// The running clock's start.
    let startedAt: Date?

    /// The meta line.
    var metaText: String { metaParts.joined(separator: " · ") }

    /// Whether a notices or continuity chip shows.
    var hasSupervisionChip: Bool { showsContinuity || noticeCount > 0 }

    /// Meta shows only when the window is not narrow, the task is not pending, and the open pane is not
    /// already carrying a notices or continuity chip (the pin's `.hd-m05-bar__center` rule).
    func showsMeta(isNarrow: Bool) -> Bool {
        !isNarrow && !isPending && !metaParts.isEmpty && !(paneOpen && hasSupervisionChip)
    }

    /// The chips' inputs for the toolbar.
    func chips(isNarrow: Bool) -> TaskTopBarChips {
        TaskTopBarChips(showsContinuity: showsContinuity, noticeCount: noticeCount, accessText: accessText, isNarrow: isNarrow)
    }
}

// MARK: - TaskTopBarChips

/// The trailing chips' quantised inputs, part of the toolbar snapshot.
struct TaskTopBarChips: Equatable, Sendable {
    let showsContinuity: Bool
    let noticeCount: Int
    /// `nil` hides the access chip.
    let accessText: String?
    let isNarrow: Bool

    /// The notices chip text: "1 notice", "N notices"; the count alone when narrow.
    var noticesText: String { isNarrow ? String(noticeCount) : "\(noticeCount) notice\(noticeCount == 1 ? "" : "s")" }
    var noticesLabel: String { "Show \(noticeCount) notice\(noticeCount == 1 ? "" : "s")" }
    static let continuityText = "Observation resumed"
    static let continuityLabel = "Observation resumed after a restart. Show details."
    var accessLabel: String { "\(accessText ?? ""). Show what was enforced." }

    /// The one place the chip rules live: continuity and notices come from the inspector facts, and the access chip
    /// is absent when the task has no `freedom` or is pending.
    static func make(task: TaskInfo, model: InspectorModel?, isNarrow: Bool) -> TaskTopBarChips {
        TaskTopBarChips(
            showsContinuity: model?.showsContinuity == true,
            noticeCount: model?.notices.count ?? 0,
            accessText: TaskBadgeModel.isPending(task.status) ? nil : task.freedom.map(AccessLabel.text),
            isNarrow: isNarrow
        )
    }
}

// MARK: - Building

extension TaskDetailViewModel {
    /// The top bar content for the shown task; `nil` before the task is known.
    var topBarContent: TaskTopBarContent? {
        guard let task, let evidence = snapshotEvidence else { return nil }
        let isPending = TaskBadgeModel.isPending(task.status)
        let model = inspectorModel
        let chips = TaskTopBarChips.make(task: task, model: model, isNarrow: false)
        var parts = [TaskFactsText.harness(task: task, model: model)]
        if !task.repoPath.isEmpty { parts.append(Format.repoName(task.repoPath)) }
        if let turnsText { parts.append(turnsText) }
        return TaskTopBarContent(
            title: title,
            badge: isStatusUnavailable ? .statusUnavailable : TaskBadgeModel.make(evidence: evidence, startedAt: task.startedAt),
            metaParts: parts.filter { !$0.isEmpty },
            isBusy: isBusy,
            isPending: isPending,
            paneOpen: topBarPaneOpen,
            showsContinuity: chips.showsContinuity,
            noticeCount: chips.noticeCount,
            accessText: chips.accessText,
            startedAt: task.startedAt
        )
    }
}

// MARK: - TaskDetailVM

extension TaskDetailVM {
    /// This VM's writer identity for the top bar holder.
    var topBarTag: TaskTopBarHolder.Tag {
        TaskTopBarHolder.Tag(writer: ObjectIdentifier(self), conversationID: topBarConversationID)
    }

    /// Forgets the last written content, so a reappearance publishes again even when identical, and asks to be shown.
    func activateTopBar() {
        lastPublishedTopBar = nil
        if chrome == .standalone { routing.activateTopBar(tag: topBarTag) }
    }

    /// Writes the current content when this is a mounted standalone VM and the content changed.
    func publishTopBar() {
        // A listing change can shift the normalised id between build and appear, failing the first activation; the
        // holder still gates on the shown conversation, so asking again on every publish is safe.
        if chrome == .standalone, isMounted { routing.retryTopBarActivation(tag: topBarTag) }
        guard chrome == .standalone, isMounted, let content = topBarContent, content != lastPublishedTopBar else { return }
        lastPublishedTopBar = content
        routing.publishTopBar(content, tag: topBarTag)
    }

    /// Clears this writer's entry and forgets what was written, so identical content restored later republishes.
    func clearTopBarPublication() {
        lastPublishedTopBar = nil
        if chrome == .standalone { routing.clearTopBar(tag: topBarTag) }
    }

    /// Clears the entry and gives up the shown writer role; the screen is going away.
    func releaseTopBar() {
        clearTopBarPublication()
        if chrome == .standalone { routing.deactivateTopBar(tag: topBarTag) }
    }
}
