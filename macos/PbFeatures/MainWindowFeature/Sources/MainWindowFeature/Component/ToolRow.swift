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
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
            HStack(spacing: PbRadius.Metrics.spacing6) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: PbRadius.Metrics.spacing6) {
                    Image(systemName: icon)
                        .font(.pb(.headline))
                        .frame(width: PbRadius.Metrics.activityIconSize)
                        .foregroundStyle(model.call.category == "workflow_protocol_error" ? Color.failedRed : Color.secondaryText)
                    Text(model.call.tool).font(.pb(.body, weight: .bold))
                    Text(model.call.headline)
                        .font(.pb(.secondary, design: .monospaced))
                        .foregroundStyle(Color.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: PbRadius.Metrics.spacing4)
                    if let result = model.result {
                        if let code = result.exitCode {
                            Text("exit \(code)")
.font(.pb(.caption))
.monospacedDigit()
                                .foregroundStyle(code == 0 ? Color.doneGreen : Color.failedRed)
                        } else if !result.ok, model.call.category != "workflow_protocol_error" {
                            Text("failed").font(.pb(.caption)).foregroundStyle(Color.failedRed)
                        }
                    } else if model.live {
                        RunningSpinner(size: PbRadius.Metrics.spacing12)
                    } else {
                        Text("no result").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                    }
                    if model.call.category == "workflow_protocol_error" {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.pb(.caption, weight: .semibold))
.foregroundStyle(Color.secondaryText)
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
                        .font(.pb(.secondary, design: .monospaced))
                        .lineLimit(expanded ? nil : 6)
                        .textSelection(.enabled)
                        .padding(PbRadius.Metrics.spacing6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: PbRadius.button).fill(Color.codeFill))
                } else if expanded {
                    Text(model.call.inputPreview).font(.pb(.secondary, design: .monospaced)).textSelection(.enabled).foregroundStyle(Color.secondaryText)
                }
            }
        }
    }
    
    private var icon: String {
        switch model.call.category {
        case "workflow_protocol_error": "xmark.circle.fill"
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
/// an edit's old/new lines as a diff-style preview (§5.4): each line carries its own tinted
/// background — `diffRemovedFill` for removed, `diffAddedFill` for added — on a `codeFill` body.
/// No Model needed, and no `+N −M` counts: the events carry none, so none are invented.
struct EditPreview: View {
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.zero) {
            ForEach(Array(old.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).enumerated()), id: \.offset) { _, line in
                diffLine("− " + line, tint: Color.diffRemovedFill, foreground: Color.failedRed)
            }
            ForEach(Array(new.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).enumerated()), id: \.offset) { _, line in
                diffLine("+ " + line, tint: Color.diffAddedFill, foreground: Color.doneGreen)
            }
        }
        .font(.pb(.secondary, design: .monospaced))
        .padding(PbRadius.Metrics.spacing6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PbRadius.button).fill(Color.codeFill))
    }

    private func diffLine(_ text: String, tint: Color, foreground: Color) -> some View {
        Text(text)
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, PbRadius.Metrics.spacing4)
            .padding(.vertical, PbRadius.Metrics.spacing2)
            .background(tint)
    }
}

#if DEBUG
private struct ToolRowPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing10) {
            row(PreviewFixtures.toolItem(), live: false)
            row(PreviewFixtures.toolItem(command: "swift test --filter LoginTests", pending: true), live: true)
            row(PreviewFixtures.toolItem(outputTail: "error: build failed", exitCode: 1, ok: false), live: false)
            row(PreviewFixtures.editItem(path: "/repo/A.swift", old: "let a = 1", new: "let a = 2", seq: 1), live: false)
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(width: PbRadius.Metrics.toolRowPreviewWidth)
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

#Preview("Edit preview - light") {
    EditPreview(old: "let cached = false\nreturn cached", new: "let cached = true\nreturn cached")
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
.preferredColorScheme(.light)
}

#Preview("Edit preview - dark") {
    EditPreview(old: "let cached = false\nreturn cached", new: "let cached = true\nreturn cached")
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
.preferredColorScheme(.dark)
}
#endif
