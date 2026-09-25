//
//  ChangesPaneView.swift
//  MainWindowFeature
//
//  Ported from the app target's `TimelineViews.swift` (`ChangesPane`, `DiffView`,
//  `UntrackedPreview`). The untracked-file read moves behind `TaskDetailUseCase.previewFile(path:)`
//  → `PbRepository.FilePreviewRepository` (decision 9); everything else is unchanged. Diff selection
//  is local `@State`, defaulting to the first diff, per the screen shape's own allowance.
//

import MonitorCore
import PbRepository
import PbUI
import SwiftUI

// MARK: - ChangesPaneModel

struct ChangesPaneModel {
    let changes: GitChanges?
    let error: String?
    let commands: [(command: String, exitCode: Int?, ok: Bool?)]
    /// The agent's own summary, shown only once the task is terminal — already resolved by the VM
    /// (snapshot summary, falling back to the listing's, per `ChangesPane`'s own rule, unlike the
    /// Parallel column).
    let summary: String?
    let onReload: () -> Void
    let previewFile: (String) async -> FilePreviewResult
    
    @MainActor
    static let empty = ChangesPaneModel(changes: nil, error: nil, commands: [], summary: nil, onReload: {}, previewFile: { _ in .unreadable })
    
    /// The failures to list: every one once compared against the baseline, otherwise the first
    /// (which is always the comparison failure itself) is dropped (F4-42).
    static func visibleFailures(_ changes: GitChanges) -> [GitFailure] {
        changes.comparedWithBase ? changes.failures : Array(changes.failures.dropFirst())
    }
}

// MARK: - ChangesPaneView

struct ChangesPaneView: View {
    let model: ChangesPaneModel
    @State private var selectedPath: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let changes = model.changes {
                    HStack(alignment: .top) {
                        Banner(icon: changes.comparedWithBase ? "checkmark.seal" : "exclamationmark.triangle",
                               title: changes.comparedWithBase ? "Checked against git" : "Could not check against git",
                               text: (
                                [changes.summaryLine] + changes.labels
                                + ChangesPaneModel.visibleFailures(changes).map { "git \($0.query): \($0.detail)" }
                               ).joined(separator: "\n"),
                               tint: changes.comparedWithBase ? .accentLink : .failedRed)
                        Button("Refresh", action: model.onReload)
                    }
                    if !changes.files.isEmpty {
                        SectionLabel(text: "Files")
                        VStack(spacing: 0) {
                            ForEach(changes.files) { file in
                                Button {
                                    selectedPath = file.path
                                } label: {
                                    HStack {
                                        Text(file.isUntracked ? "A" : file.status)
                                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(file.status == "D" ? Color.failedRed : Color.doneGreen)
                                            .frame(width: 16)
                                        Text(file.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        if file.isUntracked { Text("untracked").font(.system(size: 10)).foregroundStyle(.secondary) }
                                        Spacer()
                                        if let added = file.added, let removed = file.removed {
                                            Text("+\(added)").foregroundStyle(Color.doneGreen)
                                            Text("−\(removed)").foregroundStyle(Color.failedRed)
                                        }
                                    }
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.vertical, 5)
                                    .padding(.horizontal, 8)
                                    .background(selectedPath == file.path ? Color.selectedRow : .clear)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
                    }
                } else if let error = model.error {
                    Banner(icon: "exclamationmark.triangle", title: "Changes unavailable", text: error, tint: .failedRed)
                } else {
                    ProgressView("Asking git…")
                }
                if let summary = model.summary {
                    SectionLabel(text: "Agent summary (the agent's own words)")
                    MarkdownText(text: summary)
                }
                if !model.commands.isEmpty {
                    SectionLabel(text: "Commands run")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(model.commands.enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 8) {
                                Text(entry.exitCode.map { "exit \($0)" } ?? (entry.ok == false ? "failed" : (entry.ok == nil ? "running" : "ok")))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle((entry.exitCode ?? (entry.ok == false ? 1 : 0)) == 0 ? Color.doneGreen : Color.failedRed)
                                    .frame(width: 54, alignment: .leading)
                                Text(entry.command).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let changes = model.changes, let path = selectedPath ?? changes.diffs.first?.path {
                    if let diff = changes.diffs.first(where: { $0.path == path }) {
                        DiffView(diff: diff)
                    } else if changes.files.first(where: { $0.path == path })?.isUntracked == true {
                        UntrackedPreviewView(path: path, load: model.previewFile)
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: - DiffView

struct DiffView: View {
    let diff: DiffFile
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(diff.oldPath.map { "\($0) → \(diff.path)" } ?? diff.path).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("+\(diff.added) −\(diff.removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            if diff.isBinary {
                Text("Binary file").font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
            }
            ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                Text(hunk.header)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0xF0F4FA))
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        Text(line.oldNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
                        Text(line.newNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
                        Text(prefix(line.kind) + line.text).padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .background(background(line.kind))
                }
            }
        }
        .textSelection(.enabled)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
    }
    
    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+ "
        case .removed: "− "
        case .context: "  "
        case .noNewline: ""
        }
    }
    
    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: Color(hex: 0xE6F4EA)
        case .removed: Color(hex: 0xFCE8E6)
        default: .clear
        }
    }
}

// MARK: - UntrackedPreviewView

/// Untracked files have no diff; show the start of a small text file as all-new lines. The read
/// itself goes through the VM's `previewFile` closure (decision 9), never a direct `FileHandle`.
struct UntrackedPreviewView: View {
    let path: String
    let load: (String) async -> FilePreviewResult
    @State private var text: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(path) (untracked)").font(.system(size: 12, weight: .semibold))
            Text(text ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.doneGreen).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
        .task(id: path) {
            switch await load(path) {
            case .unreadable: text = "(unreadable)"
            case .binary: text = "(binary)"
            case .text(let value): text = value
            }
        }
    }
}

#if DEBUG
#Preview {
    ChangesPaneView(model: .empty)
        .frame(width: 500, height: 400)
}
#endif
