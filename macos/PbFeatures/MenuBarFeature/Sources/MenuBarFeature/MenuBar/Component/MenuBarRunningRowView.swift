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

struct MenuBarRunningRowView: View {
    let model: MenuBarRunningRowModel
    let onTap: () -> Void
    
    var body: some View {
        Button(action: onTap) {
            ActivityCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        RunningSpinner().frame(width: 16, height: 16)
                        Text(model.title).font(.pb(.body, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(Format.clock(elapsed(at: context.date)))
                                .font(.pb(.caption))
                                .monospacedDigit()
                                .foregroundStyle(Color.secondaryText)
                        }
                    }
                    HStack(spacing: 4) {
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
                    .padding(.leading, 24)
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
        VStack(alignment: .leading, spacing: 8) {
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
            MenuBarRunningRowView(
                model: MenuBarRunningRowModel(
                    id: "ghi789", backend: "vibe", title: "Warming up", repoName: "",
                    startedAt: .now, durationSeconds: nil, activityLine: nil, activityIsMonospaced: false
                ),
                onTap: {}
            )
        }
        .padding()
        .frame(width: 380)
        .background(Color.windowBG)
    }
}
#endif
