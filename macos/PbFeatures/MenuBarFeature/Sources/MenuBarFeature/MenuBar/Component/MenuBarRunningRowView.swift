//
//  MenuBarRunningRowView.swift
//  MenuBarFeature
//
//  Ported from the app target's `MenuBarView.swift` (`MenuRunningRow`). A dumb component: the live
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
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    BackendBadge(backend: model.backend, size: 18)
                    Text(model.title).font(.pb(.body, weight: .medium)).lineLimit(1)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.clock(elapsed(at: context.date))).font(.pb(.secondary)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let activityLine = model.activityLine {
                    Text(activityLine)
                        .font(model.activityIsMonospaced ? .pb(.secondary, design: .monospaced) : .pb(.secondary))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(model.activityIsMonospaced ? .middle : .tail)
                }
                ProgressView().progressViewStyle(.linear).controlSize(.mini)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    
    private func elapsed(at date: Date) -> TimeInterval? {
        guard let startedAt = model.startedAt else { return model.durationSeconds }
        return max(0, date.timeIntervalSince(startedAt))
    }
}

#if DEBUG
#Preview {
    VStack(alignment: .leading, spacing: 10) {
        MenuBarRunningRowView(
            model: MenuBarRunningRowModel(
                id: "abc123", backend: "claude", title: "Fix the login bug", startedAt: .now.addingTimeInterval(-42),
                durationSeconds: nil, activityLine: "grep -rn \"login\" .", activityIsMonospaced: true
            ),
            onTap: {}
        )
        MenuBarRunningRowView(
            model: MenuBarRunningRowModel(
                id: "def456", backend: "codex", title: "Refactor the parser", startedAt: .now.addingTimeInterval(-10),
                durationSeconds: nil, activityLine: "Looking at the tokenizer next.", activityIsMonospaced: false
            ),
            onTap: {}
        )
    }
    .padding()
    .frame(width: 320)
}
#endif
