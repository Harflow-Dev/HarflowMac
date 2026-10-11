//
//  MenuBarRunningRowView.swift
//  MenuBarFeature
//
//  A running task as an `ActivityCard`: spinner, title and live elapsed clock over the current
//  activity and repo name. A dumb component: the live
//  clock reads `model.startedAt`/`durationSeconds` through its own `TimelineView` rather than
//  having the VM republish once a second.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - MenuBarRunningRowView

struct MenuBarRunningRowView: View {
    let model: MenuBarRunningRowModel
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ActivityCard {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                    HStack(spacing: PbRadius.Metrics.spacing8) {
                        RunningSpinner().frame(width: PbRadius.Metrics.statusIconSize, height: PbRadius.Metrics.statusIconSize)
                        Text(model.title).font(.pb(.body, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: PbRadius.Metrics.spacing4)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Format.clock(elapsed(at: context.date)))
                                .font(.pb(.caption))
                                .monospacedDigit()
                                .foregroundStyle(Color.tertiaryText)
                        }
                    }
                    HStack(spacing: PbRadius.Metrics.spacing4) {
                        if let activityLine = model.activityLine {
                            Text(activityLine)
                                .font(model.activityIsMonospaced ? .pb(.caption, design: .monospaced) : .pb(.caption))
                                .lineLimit(1)
                                .truncationMode(model.activityIsMonospaced ? .middle : .tail)
                        }
                        if let repoLine = Self.repoLine(model.repoName, hasActivity: model.activityLine != nil) {
                            Text(repoLine).font(.pb(.caption)).lineLimit(1).layoutPriority(1)
                        }
                    }
                    .foregroundStyle(Color.secondaryText)
                    .padding(.leading, PbRadius.Metrics.menuBarRunningRowDetailInset)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    /// The repo part of line 2: "· <repo>" after an activity, the bare repo name alone, or `nil`
    /// when the repository is unknown.
    static func repoLine(_ repoName: String, hasActivity: Bool) -> String? {
        guard !repoName.isEmpty else { return nil }
        return hasActivity ? "· \(repoName)" : repoName
    }
    
    private func elapsed(at date: Date) -> TimeInterval? {
        guard let startedAt = model.startedAt else { return model.durationSeconds }
        return max(0, date.timeIntervalSince(startedAt))
    }
}

#if DEBUG
#Preview("Running row - light") {
    MenuBarRunningRowPreview().preferredColorScheme(.light)
}

#Preview("Running row - dark") {
    MenuBarRunningRowPreview().preferredColorScheme(.dark)
}

private struct MenuBarRunningRowPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            MenuBarRunningRowView(
                model: MenuBarRunningRowModel(
                    id: "abc123", backend: "claude", title: "Fix the login bug", repoName: "polybridge",
                    startedAt: .now.addingTimeInterval(-42), durationSeconds: nil,
                    activityLine: "grep -rn \"login\" .", activityIsMonospaced: true
                ),
                onTap: {}
            )
            MenuBarRunningRowView(
                model: MenuBarRunningRowModel(
                    id: "def456", backend: "codex", title: "Refactor the parser", repoName: "polybridge",
                    startedAt: .now.addingTimeInterval(-10), durationSeconds: nil,
                    activityLine: "Looking at the tokenizer next.", activityIsMonospaced: false
                ),
                onTap: {}
            )
            // A long monospaced command truncates from the middle; a long title truncates from the tail.
            MenuBarRunningRowView(
                model: MenuBarRunningRowModel(
                    id: "long1", backend: "vibe", title: "Rework the recovery overlay's presentation and lifecycle end to end",
                    repoName: "polybridge",
                    startedAt: .now.addingTimeInterval(-125), durationSeconds: nil,
                    activityLine: "swift test --filter MenuBarViewTests/MenuBarVMTests/WorkflowMenuBarStatusVMTests",
                    activityIsMonospaced: true
                ),
                onTap: {}
            )
            // Missing data: no activity, unknown repository, and no start time — the clock falls
            // back to the recorded duration.
            MenuBarRunningRowView(
                model: MenuBarRunningRowModel(
                    id: "ghi789", backend: "vibe", title: "Warming up", repoName: "",
                    startedAt: nil, durationSeconds: 75, activityLine: nil, activityIsMonospaced: false
                ),
                onTap: {}
            )
        }
        .padding()
        .frame(width: PbRadius.Metrics.menuBarPopoverWidth)
        .background(Color.windowBG)
    }
}
#endif
