//
//  ParallelLaneHead.swift
//  MainWindowFeature
//
//  The v2 lane head (`.hd-lane__head`): one centred row with the status glyph, the task title and its caption,
//  the status caption and, for a resident lane, the lane actions menu. Design reference: HarflowDesign 4ff7d83,
//  `states-parallel-lanes.js` `lane` and `actions`, `parallel-lanes.css`.
//

import AppKit
import Foundation
import HfUI
import MonitorCore
import SwiftUI

// MARK: - LaneHeadFocusTarget

/// Whether the lane title is a keyboard target. It is one only while a requested focus move is in flight or holds.
struct LaneHeadFocusTarget: Equatable {
    /// How long a requested focus move is given before it is judged to have failed.
    static let settleDelay: Duration = .milliseconds(200)
    private(set) var isTarget = false

    mutating func request() { isTarget = true }
    /// The deferred focus attempt finished; a title that did not take focus stops being a target.
    mutating func attemptFinished(focused: Bool) { if !focused { isTarget = false } }
    /// Focus left the title, or the head disappeared.
    mutating func focusLost() { isTarget = false }
}

// MARK: - ParallelLaneHead

struct ParallelLaneHead: View {
    let title: String
    let caption: String
    let task: TaskInfo
    let status: TaskBadgeModel
    /// The lane actions menu's "Open task"; `nil` draws no menu (the resident placeholder).
    var onOpenTask: (() -> Void)?
    /// Changes when the head should take keyboard and VoiceOver focus (after "Load current activity" completes).
    var focusToken = 0

    @FocusState private var titleFocused: Bool
    /// The title is a keyboard target only while it is receiving focus after "Load current activity"; otherwise it is
    /// plain text and never draws a focus ring or takes initial focus.
    @State private var focusTarget = LaneHeadFocusTarget()
    @AccessibilityFocusState private var titleAccessibilityFocused: Bool

    private typealias Metrics = TaskScreenStyle.Lane

    var body: some View {
        HStack(alignment: .center, spacing: Metrics.headGap) {
            StatusIcon(status: task.status).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(TaskScreenStyle.sans(size: Metrics.headTitle.size, weight: .semibold))
                    .lineSpacing(TaskScreenStyle.lineSpacing(Metrics.headTitle))
                    .foregroundStyle(TaskScreenStyle.Colors.text.color)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .focusable(focusTarget.isTarget)
                    .focused($titleFocused)
                    .accessibilityFocused($titleAccessibilityFocused)
                Text(caption)
                    .font(TaskScreenStyle.sans(size: Metrics.headCaptionSize))
                    .foregroundStyle(TaskScreenStyle.Colors.textTertiary.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            statusCaption
            if let onOpenTask { actionsMenu(onOpenTask) }
        }
        .onChange(of: focusToken) { _, _ in
            focusTarget.request()
            DispatchQueue.main.async {
                titleFocused = true
                titleAccessibilityFocused = true
                // The attempt can fail (the head is not in a key window, or focus lands elsewhere): the title must not
                // stay a Tab stop.
                Task { @MainActor in
                    try? await Task.sleep(for: LaneHeadFocusTarget.settleDelay)
                    focusTarget.attemptFinished(focused: titleFocused)
                }
            }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { focusTarget.focusLost() }
        }
        .onDisappear { focusTarget.focusLost() }
    }

    // MARK: Status

    @ViewBuilder private var statusCaption: some View {
        let content = HStack(spacing: 4) {
            Text(status.label)
            clock
        }
        .font(TaskScreenStyle.sans(size: Metrics.headCaptionSize))
        .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
        .lineLimit(1)
        .fixedSize()
        if case .live = status.clock {
            content.accessibilityElement(children: .combine).accessibilityAddTraits(.updatesFrequently)
        } else {
            content.accessibilityElement(children: .ignore).accessibilityLabel(fixedAccessibilityText)
        }
    }

    @ViewBuilder private var clock: some View {
        switch status.clock {
        case .none: EmptyView()
        case let .fixed(seconds): Text(Format.clock(seconds)).monospacedDigit().fixedSize()
        case let .live(start): TaskLiveClock(start: start)
        }
    }

    private var fixedAccessibilityText: String {
        if case let .fixed(seconds) = status.clock { "\(status.label), \(Format.clock(seconds))" } else { status.label }
    }

    // MARK: Menu

    private func actionsMenu(_ open: @escaping () -> Void) -> some View {
        Menu {
            Button(action: open) { Label("Open task", systemImage: "arrow.up.forward.square") }
        } label: {
            Image(systemName: "ellipsis")
                .foregroundStyle(TaskScreenStyle.Colors.textSecondary.color)
                .frame(width: Metrics.menuSize, height: Metrics.menuSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Lane actions")
    }
}
