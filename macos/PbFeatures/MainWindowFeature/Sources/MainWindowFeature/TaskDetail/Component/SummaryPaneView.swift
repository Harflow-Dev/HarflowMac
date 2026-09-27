//
//  SummaryPaneView.swift
//  MainWindowFeature
//
//  The Summary tab (piece 2/3 of the Monitor architecture plan): what the agent itself reported,
//  never git. Replaces the git-backed Changes tab outright — "Files the agent edited" reads the
//  agent's own tool_call/tool_result pairs (`MonitorCore.EditedFiles`), not a diff.
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - SummaryPaneModel

struct SummaryPaneModel {
    let finalAnswer: String?
    /// Shown in place of `finalAnswer` when it is nil — depends on whether the task is still
    /// running, so it is resolved once here rather than re-derived by the view.
    let finalAnswerPlaceholder: String

    /// Each denial's description, then each notice, in that order; empty hides the section.
    let refusalLines: [String]

    let editedFilesAvailability: EventAvailability
    let editedFiles: [EditedFile]
    /// A note shown alongside the (possibly partial) edited-files list — e.g. when a conversation's
    /// earlier turns' logs are not all loaded yet (Monitor piece 7, Review round 1 item 6). `nil`
    /// when everything known is complete.
    let editedFilesNote: String?

    let numTurns: Int?
    let inputTokens: Int?
    let outputTokens: Int?
    let costUSD: Double?

    /// `PbUI.EnforcementText.lines(_:)` — empty hides the section.
    let enforcementLines: [String]

    var hasUsage: Bool { numTurns != nil || inputTokens != nil || outputTokens != nil || costUSD != nil }

    static let empty = SummaryPaneModel(
        finalAnswer: nil, finalAnswerPlaceholder: "No answer yet.", refusalLines: [],
        editedFilesAvailability: .loading, editedFiles: [], editedFilesNote: nil, numTurns: nil, inputTokens: nil,
        outputTokens: nil, costUSD: nil, enforcementLines: []
    )

    /// Combines every conversation member's own `eventsAvailability` into one overall state plus an
    /// optional note (Monitor piece 7, Review round 1 item 6): complete only once every member is
    /// `.available`; when some but not all are, the KNOWN part still shows, with a note saying
    /// earlier turns aren't all in yet; `.loading` while nothing is known yet; `.unavailable` only
    /// once every member has settled and none could be read at all.
    static func aggregateAvailability(_ availabilities: [EventAvailability]) -> (EventAvailability, note: String?) {
        if availabilities.allSatisfy({ $0 == .available }) { return (.available, nil) }
        if availabilities.contains(.available) { return (.available, "Edit history for earlier turns isn't available.") }
        if availabilities.contains(.loading) { return (.loading, nil) }
        return (.unavailable, nil)
    }

    /// The token keys differ by backend — claude/codex report `input_tokens`/`output_tokens`,
    /// opencode reports `input`/`output` — so this falls back **by key**, never by backend name
    /// (`TaskInfo` carries no backend-specific usage type, only the raw object).
    static func tokens(from usage: [String: JSONValue]?) -> (input: Int?, output: Int?) {
        guard let usage else { return (nil, nil) }
        let input = usage["input_tokens"]?.intValue ?? usage["input"]?.intValue
        let output = usage["output_tokens"]?.intValue ?? usage["output"]?.intValue
        return (input, output)
    }

    /// One denial's description: its `command`, else its `title`, else "an action" — the same
    /// fallback order `vibe.py`'s `_callback_description` uses, since a recognised denial can
    /// carry neither field.
    static func denialLine(_ denial: JSONValue) -> String {
        guard let object = denial.objectValue else { return "an action" }
        return object["command"]?.stringValue ?? object["title"]?.stringValue ?? "an action"
    }

    /// Builds the whole Summary tab from a task and its raw event stream. A pure mapping (decision
    /// 9), so it is testable without a VM harness. `summary` is passed in already resolved (the
    /// VM's own snapshot-preferring rule — `summary` is a snapshot-only field, nil on a bare
    /// listing) rather than read off `task` here, so this stays a pure function of its arguments.
    static func build(
        task: TaskInfo, summary: String?, events: [TaskEvent], eventsAvailability: EventAvailability, editedFilesNote: String? = nil
    ) -> SummaryPaneModel {
        let hasSummary = summary?.isEmpty == false
        let (inputTokens, outputTokens) = tokens(from: task.raw["usage"]?.objectValue)
        return SummaryPaneModel(
            finalAnswer: hasSummary ? summary : nil,
            finalAnswerPlaceholder: task.status.isRunning ? "No answer yet." : "No final answer.",
            refusalLines: task.permissionDenials.map(denialLine) + task.notices,
            editedFilesAvailability: eventsAvailability,
            editedFiles: EditedFiles.build(from: events, repoPath: task.repoPath),
            editedFilesNote: editedFilesNote,
            numTurns: task.numTurns, inputTokens: inputTokens, outputTokens: outputTokens, costUSD: task.totalCostUSD,
            enforcementLines: EnforcementText.lines(task.enforcement)
        )
    }

    /// The conversation-level version of `build(task:summary:events:eventsAvailability:)` (Monitor
    /// piece 7): "Files the agent edited" pairs each member's own events independently
    /// (`EditedFiles.build(fromMembers:repoPath:)`, Review round 1 item 1), and availability is
    /// aggregated across every member's own lease (item 6).
    static func build(
        task: TaskInfo, summary: String?, memberEventsOldestFirst: [[TaskEvent]], memberAvailabilities: [EventAvailability]
    ) -> SummaryPaneModel {
        let hasSummary = summary?.isEmpty == false
        let (inputTokens, outputTokens) = tokens(from: task.raw["usage"]?.objectValue)
        let (availability, note) = aggregateAvailability(memberAvailabilities)
        return SummaryPaneModel(
            finalAnswer: hasSummary ? summary : nil,
            finalAnswerPlaceholder: task.status.isRunning ? "No answer yet." : "No final answer.",
            refusalLines: task.permissionDenials.map(denialLine) + task.notices,
            editedFilesAvailability: availability,
            editedFiles: EditedFiles.build(fromMembers: memberEventsOldestFirst, repoPath: task.repoPath),
            editedFilesNote: note,
            numTurns: task.numTurns, inputTokens: inputTokens, outputTokens: outputTokens, costUSD: task.totalCostUSD,
            enforcementLines: EnforcementText.lines(task.enforcement)
        )
    }
}

// MARK: - SummaryPaneView

struct SummaryPaneView: View {
    let model: SummaryPaneModel

    @State private var finalAnswerExpanded = true
    @State private var refusalsExpanded = false
    @State private var editedFilesExpanded = false
    @State private var usageExpanded = false
    @State private var enforcementExpanded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                group("Final answer", isExpanded: $finalAnswerExpanded) {
                    if let answer = model.finalAnswer {
                        MarkdownText(text: answer)
                    } else {
                        Text(model.finalAnswerPlaceholder).font(.pb(.body)).foregroundStyle(.secondary)
                    }
                }

                if !model.refusalLines.isEmpty {
                    group("Refusals & warnings", isExpanded: $refusalsExpanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(model.refusalLines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.pb(.secondary)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }

                editedFilesSection

                if model.hasUsage {
                    group("Usage & cost", isExpanded: $usageExpanded) { usageRows }
                }

                if !model.enforcementLines.isEmpty {
                    group("What was enforced", isExpanded: $enforcementExpanded) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(model.enforcementLines, id: \.self) { line in
                                Text(line).font(.pb(.secondary)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private var editedFilesSection: some View {
        switch model.editedFilesAvailability {
        case .loading:
            group("Files the agent edited", isExpanded: $editedFilesExpanded) {
                ProgressView().controlSize(.small)
            }
        case .unavailable:
            group("Files the agent edited", isExpanded: $editedFilesExpanded) {
                Text("Edit history isn't available for this task.").font(.pb(.secondary)).foregroundStyle(.secondary)
            }
        case .available:
            if !model.editedFiles.isEmpty {
                group("Files the agent edited", isExpanded: $editedFilesExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("As reported by the agent's own edit tools — not a git diff; changes made by shell commands aren't listed.")
                            .font(.pb(.caption))
                            .foregroundStyle(.secondary)
                        if let note = model.editedFilesNote {
                            Text(note).font(.pb(.caption)).foregroundStyle(.secondary)
                        }
                        VStack(spacing: 0) {
                            ForEach(model.editedFiles) { file in
                                HStack(spacing: 6) {
                                    statusBadge(file.status)
                                    Text(file.path).font(.pb(.secondary, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    if file.status == .unconfirmed {
                                        Text("no result recorded").font(.pb(.caption)).foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.vertical, 3)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusBadge(_ status: EditedFileStatus) -> some View {
        let (symbol, color): (String, Color) = switch status {
        case .edited: ("✓", Color.doneGreen)
        case .failed: ("✗", Color.failedRed)
        case .unconfirmed: ("?", Color.secondary)
        }
        return Text(symbol).font(.pb(.caption, weight: .bold, design: .monospaced)).foregroundStyle(color).frame(width: 12)
    }

    @ViewBuilder
    private var usageRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let turns = model.numTurns { usageRow("Turns", "\(turns)") }
            if let input = model.inputTokens { usageRow("Input tokens", "\(input)") }
            if let output = model.outputTokens { usageRow("Output tokens", "\(output)") }
            if let cost = model.costUSD { usageRow("Cost", String(format: "$%.4f", cost)) }
        }
    }

    private func usageRow(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(.pb(.secondary)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.pb(.secondary, design: .monospaced))
        }
    }

    @ViewBuilder
    private func group(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            // macOS centres a DisclosureGroup's content unless it is given the full width.
            content().padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.pb(.body, weight: .semibold))
        }
    }
}

#if DEBUG
#Preview {
    SummaryPaneView(model: .empty)
        .frame(width: 500, height: 400)
}
#endif
