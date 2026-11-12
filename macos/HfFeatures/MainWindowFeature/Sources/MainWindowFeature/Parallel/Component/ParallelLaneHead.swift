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
    @State private var titleIsFocusTarget = false
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
                    .focusable(titleIsFocusTarget)
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
            titleIsFocusTarget = true
            DispatchQueue.main.async {
                titleFocused = true
                titleAccessibilityFocused = true
            }
        }
        .onChange(of: titleFocused) { _, focused in
            if !focused { titleIsFocusTarget = false }
        }
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
