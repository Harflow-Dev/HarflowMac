//
//  ToolRow.swift
//  MainWindowFeature
//
//  A dumb Model + View pair for one tool-call row, shared by the Parallel screen and (eventually,
//  Phase 4d) TaskDetail. Ported byte-for-byte from the app target's `TimelineViews.swift`
//  (`ToolRow`/`EditPreview`) — the old copies stay there untouched for TaskDetail's own use until it
//  migrates (this dispatch's own AGENTS.md / the phase-4 brief's scope line).
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - ToolRowModel

/// Presentation data for one tool-call row: the call, its result (if the tool has finished), and
/// whether the owning task is still running (drives the spinner for a call with no result yet).
struct ToolRowModel {
    let call: TaskEvent.ToolCall
    let result: TaskEvent.ToolResult?
    let live: Bool
}

// MARK: - ToolRow

/// A single tool-call row, expandable to show its output/input preview. Dumb component (aside from
/// its own `expanded` toggle, allowed for a component per the root AGENTS.md's Component Models
/// section), ported unchanged from the old `TimelineViews.swift`.
struct ToolRow: View {
    let model: ToolRowModel
    @State private var expanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).frame(width: 14).foregroundStyle(.secondary)
                    Text(model.call.tool).font(.pb(.body, weight: .medium))
                    Text(model.call.headline).font(.pb(.secondary, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let result = model.result {
                        if let code = result.exitCode {
                            Text("exit \(code)").font(.pb(.caption)).foregroundStyle(code == 0 ? Color.doneGreen : Color.failedRed)
                        } else if !result.ok {
                            Text("failed").font(.pb(.caption)).foregroundStyle(Color.failedRed)
                        }
                    } else if model.live {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .buttonStyle(.plain)
            if let old = model.call.editOld, let new = model.call.editNew {
                EditPreview(old: old, new: new)
            }
            if expanded || (model.result == nil && model.live && model.call.category == "shell") {
                if let output = model.result?.outputTail, !output.isEmpty {
                    Text(output)
                        .font(.pb(.caption, design: .monospaced))
                        .lineLimit(expanded ? nil : 6)
                        .textSelection(.enabled)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.codeFill))
                } else if expanded {
                    Text(model.call.inputPreview).font(.pb(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                }
            }
        }
    }
    
    private var icon: String {
        switch model.call.category {
        case "read": "doc.text"
        case "search": "magnifyingglass"
        case "edit", "write": "pencil"
        case "shell": "terminal"
        case "mcp": "puzzlepiece"
        case "web": "globe"
        default: "wrench"
        }
    }
}

// MARK: - EditPreview

/// A trivial value view (plain values, per the root AGENTS.md's Component Models section) showing
/// an edit's old/new lines as a diff-style preview. No Model needed.
struct EditPreview: View {
    let old: String
    let new: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(old.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).enumerated()), id: \.offset) { _, line in
                Text("− " + line).foregroundStyle(Color.failedRed)
            }
            ForEach(Array(new.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).enumerated()), id: \.offset) { _, line in
                Text("+ " + line).foregroundStyle(Color.doneGreen)
            }
        }
        .font(.pb(.caption, design: .monospaced))
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.editPreviewFill))
    }
}

#if DEBUG
#Preview {
    let item = PreviewFixtures.toolItem()
    if case .tool(let call, let result) = item.body {
        ToolRow(model: ToolRowModel(call: call, result: result, live: false))
            .padding()
            .frame(width: 360)
    }
}
#endif
