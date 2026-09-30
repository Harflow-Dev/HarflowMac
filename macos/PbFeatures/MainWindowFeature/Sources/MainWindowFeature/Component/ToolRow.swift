//
//  ToolRow.swift
//  MainWindowFeature
//
//  A dumb Model + View pair for one tool-call row, shared by the Parallel screen and TaskDetail's
//  Activity feed (inside a `ToolGroupCardView`, or on its own for an edit). Secondary text uses the
//  palette's `secondaryText` so it stays readable on card and pill fills.
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
    @Environment(\.openURL) private var openURL
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).frame(width: 14).foregroundStyle(Color.secondaryText)
                    Text(model.call.tool).font(.pb(.body, weight: .medium))
                    Text(model.call.headline)
                        .font(.pb(.secondary, design: .monospaced))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let result = model.result {
                        if let code = result.exitCode {
                            Text("exit \(code)").font(.pb(.caption)).foregroundStyle(code == 0 ? Color.doneGreen : Color.failedRed)
                        } else if !result.ok {
                            Text("failed").font(.pb(.caption)).foregroundStyle(Color.failedRed)
                        }
                    } else if model.live {
                        RunningSpinner(size: 12)
                    } else {
                        Text("no result").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                    }
                }
            }
            .buttonStyle(.plain)
            // A sibling of the expand button, not inside it: a button nested in a button's label
            // does not reliably get its own taps.
            if let path = model.call.path, let link = FileLinks.link(forPath: path) {
                Button {
                    openURL(link)
                } label: {
                    Image(systemName: "arrow.up.forward.square").foregroundStyle(Color.secondaryText)
                }
                .buttonStyle(.borderless)
                .help("Open \((path as NSString).lastPathComponent)")
                .accessibilityLabel("Open \((path as NSString).lastPathComponent)")
            }
            }
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
                        .background(RoundedRectangle(cornerRadius: PbRadius.button).fill(Color.codeFill))
                } else if expanded {
                    Text(model.call.inputPreview).font(.pb(.caption, design: .monospaced)).textSelection(.enabled).foregroundStyle(Color.secondaryText)
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
        .background(RoundedRectangle(cornerRadius: PbRadius.button).fill(Color.editPreviewFill))
    }
}

#if DEBUG
private struct ToolRowPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(PreviewFixtures.toolItem(), live: false)
            row(PreviewFixtures.toolItem(command: "swift test --filter LoginTests", pending: true), live: true)
            row(PreviewFixtures.toolItem(outputTail: "error: build failed", exitCode: 1, ok: false), live: false)
            row(PreviewFixtures.editItem(path: "/repo/A.swift", old: "let a = 1", new: "let a = 2", seq: 1), live: false)
        }
        .padding()
        .frame(width: 420)
        .background(Color.windowBG)
    }

    @ViewBuilder
    private func row(_ item: TimelineItem, live: Bool) -> some View {
        if case .tool(let call, let result) = item.body {
            ToolRow(model: ToolRowModel(call: call, result: result, live: live))
        }
    }
}

#Preview("Tool row - light") { ToolRowPreview().preferredColorScheme(.light) }
#Preview("Tool row - dark") { ToolRowPreview().preferredColorScheme(.dark) }
#endif
