//
//  MenuBarRefreshNote.swift
//  MenuBarFeature
//

import HfRepository
import HfUI
import MonitorCore
import SwiftUI

// MARK: - MenuBarRefreshNote

/// The popover note shown when listing the work failed while the runtime is ready (`menu-bar/engine-call-failed`): a title,
/// the engine's sentence and Retry, with the last known rows kept below. Like the sidebar's note it carries no refusal code.
struct MenuBarRefreshNote: Equatable, Sendable {
    static let title = "Couldn't refresh your work"
    static let retryTitle = "Retry"

    let message: String

    /// Pure and safe off the main actor. A managed-runtime-unavailable error belongs to the runtime card, not to a note.
    nonisolated static func note(runtimeReady: Bool, listError: ToolError?) -> MenuBarRefreshNote? {
        guard runtimeReady, let listError, !listError.isManagedRuntimeUnavailable else { return nil }
        return MenuBarRefreshNote(message: LoadingWorkError(error: listError).message)
    }
}

// MARK: - MenuBarRefreshNoteView

struct MenuBarRefreshNoteView: View {
    let note: MenuBarRefreshNote
    let retry: () -> Void

    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                Text(MenuBarRefreshNote.title).font(.hf(.body, weight: .semibold)).foregroundStyle(Color.primaryText)
                Text(note.message)
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.primaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(MenuBarRefreshNote.retryTitle, action: retry)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("menu-bar-refresh-retry")
        }
        .padding(.vertical, HfRadius.Metrics.spacing8)
        .padding(.leading, HfRadius.Metrics.spacing12)
        .padding(.trailing, HfRadius.Metrics.spacing8)
        .background(Color.dangerBG, in: RoundedRectangle(cornerRadius: HfRadius.row))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menu-bar-refresh-note")
    }
}

#if DEBUG
#Preview("Refresh note, light") {
    MenuBarRefreshNoteView(note: .init(message: "harflow-ctl task-list-page exited 1 without a JSON answer."), retry: {})
        .frame(width: 348)
.padding()
.preferredColorScheme(.light)
}

#Preview("Refresh note, dark") {
    MenuBarRefreshNoteView(note: .init(message: "harflow-ctl task-list-page exited 1 without a JSON answer."), retry: {})
        .frame(width: 348)
.padding()
.preferredColorScheme(.dark)
}
#endif
