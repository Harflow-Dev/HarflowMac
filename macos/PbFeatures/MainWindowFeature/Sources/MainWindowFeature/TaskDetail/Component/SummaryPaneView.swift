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

// MARK: - SummaryHeroModel

/// The Summary's headline (decision D9): status icon, a status/duration sentence, and a
/// "<Backend> · N turns" subline.
struct SummaryHeroModel: Equatable {
    let status: TaskStatus
    let backend: String
    /// The whole headline for a settled task ("Done in 21 min", or just "Done" when no exit was
    /// observed). While running the view ticks "Running · m:ss" itself from `startedAt`.
    let headline: String
    /// While running: when it started, and the recorded duration `TaskInfo.elapsed(now:)` falls back
    /// to when it has no start time.
    let startedAt: Date?
    let fallbackElapsed: TimeInterval?
    /// "3 turns" — backend `numTurns` only, nil when unreported.
    let turnsText: String?

    var isRunning: Bool { status.isRunning }
}

// MARK: - SummaryStatTile

struct SummaryStatTile: Equatable, Identifiable {
    let title: String
    let value: String
    var id: String { title }
}

// MARK: - SummaryFileRow

/// One "Files edited" row: the file name plus its dim LAST parent folder only ("TaskRow.swift" in
/// "Component"), with the full path kept for the tooltip and the accessibility label.
struct SummaryFileRow: Equatable, Identifiable {
    let id: String
    let name: String
    let parentFolder: String?
    let fullPath: String
    let status: EditedFileStatus
    let accessibilityLabel: String

    init(_ file: EditedFile) {
        let nsPath = file.path as NSString
        let folder = nsPath.deletingLastPathComponent
        self.id = file.path
        self.name = nsPath.lastPathComponent
        self.parentFolder = (folder.isEmpty || folder == ".") ? nil : (folder as NSString).lastPathComponent
        self.fullPath = file.path
        self.status = file.status
        self.accessibilityLabel = switch file.status {
        case .edited: "Edited \(file.path)"
        case .failed: "Edit failed \(file.path)"
        case .unconfirmed: "Edit unconfirmed, no result recorded \(file.path)"
        }
    }
}

// MARK: - SummaryPaneModel

struct SummaryPaneModel {
    let hero: SummaryHeroModel?

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
    var additionalFileCount = 0
    var onLoadMoreFiles: (() -> Void)?

    var editedFileRows: [SummaryFileRow] { editedFiles.map(SummaryFileRow.init) }

    /// How many file rows show before the rest collapses behind the "Show all N" button (item 13).
    static let fileRowCollapseThreshold = 8

    /// The file rows currently visible: every one of them when `showingAll`, else the first
    /// `fileRowCollapseThreshold` with the remainder reported as `hiddenCount` (0 when nothing
    /// collapses — the view hides the button then).
    static func visibleFileRows(
        _ rows: [SummaryFileRow], showingAll: Bool
    ) -> (rows: [SummaryFileRow], hiddenCount: Int) {
        guard !showingAll, rows.count > fileRowCollapseThreshold else { return (rows, 0) }
        return (Array(rows.prefix(fileRowCollapseThreshold)), rows.count - fileRowCollapseThreshold)
    }

    /// Tokens / Cost, each only when reported. Duration has no tile (item 9): the hero headline
    /// already says it, so the row as a whole shows only once Tokens or Cost is reported.
    var statTiles: [SummaryStatTile] {
        var tiles: [SummaryStatTile] = []
        if inputTokens != nil || outputTokens != nil {
            let input = inputTokens.map(Self.tokenCount) ?? "–"
            let output = outputTokens.map(Self.tokenCount) ?? "–"
            tiles.append(SummaryStatTile(title: "Tokens (in / out)", value: "\(input) / \(output)"))
        }
        if let costUSD { tiles.append(SummaryStatTile(title: "Cost", value: String(format: "$%.4f", costUSD))) }
        return tiles
    }

    @MainActor static let empty = SummaryPaneModel(
        hero: nil, finalAnswer: nil, finalAnswerPlaceholder: "No answer yet.", refusalLines: [],
        editedFilesAvailability: .loading, editedFiles: [], editedFilesNote: nil, numTurns: nil, inputTokens: nil,
        outputTokens: nil, costUSD: nil
    )

    /// "45 sec", "21 min", "1 h 5 min".
    static func durationText(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        if total < 60 { return "\(total) sec" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }

    private static func tokenCount(_ value: Int) -> String { String(value) }

    /// D9: a settled task shows its duration only when an exit was observed (`exitCode` present);
    /// without one, the elapsed value would keep growing with "now". The duration lives in the
    /// headline alone — item 9 dropped the Duration tile that repeated it a third time.
    static func heroParts(task: TaskInfo) -> SummaryHeroModel {
        let status = task.status
        var headline = status.label
        if status.isTerminal, task.exitCode != nil, let elapsed = task.elapsed() {
            let text = durationText(elapsed)
            headline += status == .completed ? " in \(text)" : " after \(text)"
        }
        let turns = task.numTurns.map { "\($0) \($0 == 1 ? "turn" : "turns")" }
        return SummaryHeroModel(
            status: status, backend: task.backend, headline: headline, startedAt: task.startedAt,
            fallbackElapsed: task.durationSeconds, turnsText: turns
        )
    }

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
            hero: heroParts(task: task), finalAnswer: hasSummary ? summary : nil,
            finalAnswerPlaceholder: task.status.isRunning ? "No answer yet." : "No final answer.",
            refusalLines: task.permissionDenials.map(denialLine) + task.notices,
            editedFilesAvailability: eventsAvailability,
            editedFiles: EditedFiles.build(from: events, repoPath: task.repoPath),
            editedFilesNote: editedFilesNote,
            numTurns: task.numTurns, inputTokens: inputTokens, outputTokens: outputTokens, costUSD: task.totalCostUSD
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
            hero: heroParts(task: task), finalAnswer: hasSummary ? summary : nil,
            finalAnswerPlaceholder: task.status.isRunning ? "No answer yet." : "No final answer.",
            refusalLines: task.permissionDenials.map(denialLine) + task.notices,
            editedFilesAvailability: availability,
            editedFiles: EditedFiles.build(fromMembers: memberEventsOldestFirst, repoPath: task.repoPath),
            editedFilesNote: note,
            numTurns: task.numTurns, inputTokens: inputTokens, outputTokens: outputTokens, costUSD: task.totalCostUSD
        )
    }
}

// MARK: - SummaryPaneView

struct SummaryPaneView: View {
    let model: SummaryPaneModel

    @State private var refusalsExpanded = false
    @State private var showAllFiles = false

    var body: some View {
        ScrollView {
            // Item 12: hero → Result → Files edited → Refusals & warnings → stat tiles.
            VStack(alignment: .leading, spacing: 28) {
                if let hero = model.hero { heroSection(hero) }

                section("Result") {
                    if let answer = model.finalAnswer {
                        ReadingMarkdownView(text: answer)
                    } else {
                        Text(model.finalAnswerPlaceholder).font(.pb(.body)).foregroundStyle(Color.secondaryText)
                    }
                }

                editedFilesSection

                if !model.refusalLines.isEmpty { refusals }

                if !model.statTiles.isEmpty { statTiles }
            }
            .padding(24)
            .readingColumn()
        }
    }

    // MARK: Hero

    /// Item 11: the headline text stays primary; only the status icon carries the status colour
    /// (`StatusIcon` applies `StatusColor` itself).
    private func heroSection(_ hero: SummaryHeroModel) -> some View {
        HStack(alignment: .center, spacing: 12) {
            StatusIcon(status: hero.status).scaleEffect(1.6).frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                if hero.isRunning {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let elapsed = hero.startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? hero.fallbackElapsed
                        Text("Running · \(Format.clock(elapsed))").monospacedDigit()
                    }
                    .font(.pb(.hero, weight: .semibold))
                } else {
                    Text(hero.headline).font(.pb(.hero, weight: .semibold))
                }
                HStack(spacing: 4) {
                    BackendLabel(backend: hero.backend)
                    if let turns = hero.turnsText { Text("· \(turns)") }
                }
                .font(.pb(.secondary))
                .foregroundStyle(Color.secondaryText)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Stat tiles

    /// Item 10: fixed-width, leading-aligned tiles (never stretched to the pane's full width);
    /// values keep the proportional type with tabular digits rather than a monospaced design.
    private var statTiles: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(model.statTiles) { tile in
                VStack(alignment: .leading, spacing: 3) {
                    Text(tile.title).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                    Text(tile.value).font(.pb(.body, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 160, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(Color.cardFill))
                .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(Color.cardBorder, lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
        }
    }

    // MARK: Refusals & warnings

    /// Item 14: a neutral card — only the warning icon and the count carry `Color.warningFG`; the
    /// list inside keeps its collapsed-by-default disclosure.
    private var refusals: some View {
        ActivityCard {
            DisclosureGroup(isExpanded: $refusalsExpanded) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.refusalLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.pb(.secondary))
                            .foregroundStyle(Color.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 6)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.warningFG)
                    Text("Refusals & warnings")
                    Text("· \(model.refusalLines.count)").foregroundStyle(Color.warningFG)
                }
                .font(.pb(.body, weight: .semibold))
            }
        }
    }

    // MARK: Files edited

    @ViewBuilder
    private var editedFilesSection: some View {
        switch model.editedFilesAvailability {
        case .loading:
            section("Files edited") { SkeletonRows(count: 3, showsBadge: false) }
        case .unavailable:
            section("Files edited") {
                Text("Edit history isn't available for this task.").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
            }
        case .available:
            if !model.editedFiles.isEmpty {
                section("Files edited · \(model.editedFiles.count)") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("As reported by the agent's own edit tools — not a git diff; changes made by shell commands aren't listed.")
                            .font(.pb(.caption))
                            .foregroundStyle(Color.secondaryText)
                        if let note = model.editedFilesNote {
                            Text(note).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                        }
                        editedFilesCard
                    }
                }
            }
        }
    }

    /// Item 13: the list sits in a card (`ActivityCard` style: `cardFill`, hairline `cardBorder`,
    /// radius 10) with hairline dividers between rows; past `SummaryPaneModel.fileRowCollapseThreshold`
    /// rows the rest hides behind a "Show all N" button.
    private var editedFilesCard: some View {
        let allRows = model.editedFileRows
        let visible = SummaryPaneModel.visibleFileRows(allRows, showingAll: showAllFiles)
        return ActivityCard {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(visible.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    fileRow(row)
                }
                if visible.hiddenCount > 0 {
                    Divider()
                    Button("Show loaded \(allRows.count)") { showAllFiles = true }
                }
                if model.additionalFileCount > 0, let loadMore = model.onLoadMoreFiles {
                    Button("Load more files (\(model.additionalFileCount) task file entries not shown)") { showAllFiles = true; loadMore() }
                        .buttonStyle(.link)
                        .font(.pb(.secondary, weight: .medium))
                        .padding(.top, 8)
                }
            }
        }
    }

    private func fileRow(_ row: SummaryFileRow) -> some View {
        HStack(spacing: 8) {
            statusBadge(row.status)
            Text(row.name).font(.pb(.secondary, weight: .medium)).lineLimit(1)
            if let folder = row.parentFolder {
                Text(folder).font(.pb(.caption)).foregroundStyle(Color.secondaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            if row.status == .unconfirmed {
                Text("no result recorded").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }
        }
        .padding(.vertical, 6)
        .help(row.fullPath)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    private func statusBadge(_ status: EditedFileStatus) -> some View {
        let (symbol, color): (String, Color) = switch status {
        case .edited: ("✓", Color.doneGreen)
        case .failed: ("✗", Color.failedRed)
        case .unconfirmed: ("?", Color.secondaryText)
        }
        return Text(symbol).font(.pb(.caption, weight: .bold)).foregroundStyle(color).frame(width: 12)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.pb(.headline, weight: .semibold))
            content()
        }
    }
}

#if DEBUG
private enum SummaryPreviewFixtures {
    static func task(
        status: String, exitCode: Int? = 0, turns: Int? = 12, usage: Bool = true, cost: Bool = true
    ) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string("abc12345"), "backend": .string("claude"), "status": .string(status),
            "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-90))),
            "repo_path": .string("/Users/example/repo")
        ]
        if status != "running" { object["duration_seconds"] = .number(1260) }
        if let exitCode { object["exit_code"] = .number(Double(exitCode)) }
        if let turns { object["num_turns"] = .number(Double(turns)) }
        if usage { object["usage"] = .object(["input_tokens": .number(48210), "output_tokens": .number(3150)]) }
        if cost { object["total_cost_usd"] = .number(0.4213) }
        return TaskInfo(.object(object))!
    }

    static let files = [
        EditedFile(path: "macos/PbFeatures/MainWindowFeature/Sources/MainWindowFeature/TaskDetail/Component/SummaryPaneView.swift", status: .edited),
        EditedFile(path: "macos/PbFeatures/MainWindowFeature/Tests/MainWindowFeatureTests/TaskDetail/SummaryPaneModelTests.swift", status: .failed),
        EditedFile(path: "README.md", status: .unconfirmed)
    ]

    /// Twelve files, so the "Show all 12" collapse (item 13) is visible in the preview.
    static let manyFiles: [EditedFile] = (1 ... 12).map { index in
        EditedFile(path: "macos/PbFeatures/MainWindowFeature/Sources/Feature\(index)/View\(index).swift", status: .edited)
    }

    static func model(
        _ task: TaskInfo, summary: String? = "Fixed the **login bug**. The store is now warmed before it is read.",
        files: [EditedFile] = files, refusals: Bool = false
    ) -> SummaryPaneModel {
        var fields = task.raw
        if refusals { fields["notices"] = .array([.string("auto-denied: git push")]) }
        return SummaryPaneModel.build(
            task: TaskInfo(.object(fields))!, summary: summary,
            events: [], eventsAvailability: .available
        )
.with(editedFiles: files)
    }
}

private extension SummaryPaneModel {
    func with(editedFiles: [EditedFile]) -> SummaryPaneModel {
        SummaryPaneModel(
            hero: hero, finalAnswer: finalAnswer, finalAnswerPlaceholder: finalAnswerPlaceholder,
            refusalLines: refusalLines, editedFilesAvailability: editedFilesAvailability, editedFiles: editedFiles,
            editedFilesNote: editedFilesNote, numTurns: numTurns, inputTokens: inputTokens, outputTokens: outputTokens,
            costUSD: costUSD
        )
    }
}

private struct SummaryPreviewGallery: View {
    let model: SummaryPaneModel

    var body: some View {
        SummaryPaneView(model: model)
            .frame(width: 520, height: 560)
            .background(Color.windowBG)
    }
}

private typealias Fixtures = SummaryPreviewFixtures

private struct SummaryPreviewPair: View {
    let model: SummaryPaneModel
    var body: some View { SummaryPreviewGallery(model: model) }
}

private func completed() -> SummaryPaneModel { Fixtures.model(Fixtures.task(status: "completed")) }
private func running() -> SummaryPaneModel {
    Fixtures.model(Fixtures.task(status: "running", exitCode: nil), summary: nil, files: [])
}

private func failed() -> SummaryPaneModel { Fixtures.model(Fixtures.task(status: "failed", exitCode: 1), refusals: true) }
private func cancelled() -> SummaryPaneModel { Fixtures.model(Fixtures.task(status: "cancelled", exitCode: 143), summary: nil) }
private func noExit() -> SummaryPaneModel { Fixtures.model(Fixtures.task(status: "completed", exitCode: nil)) }
private func bare() -> SummaryPaneModel {
    Fixtures.model(Fixtures.task(status: "completed", turns: nil, usage: false, cost: false), files: [])
}

private func manyFiles() -> SummaryPaneModel {
    Fixtures.model(Fixtures.task(status: "completed"), files: Fixtures.manyFiles)
}

#Preview("Done - light") { SummaryPreviewPair(model: completed()).preferredColorScheme(.light) }
#Preview("Done - dark") { SummaryPreviewPair(model: completed()).preferredColorScheme(.dark) }
#Preview("Running - light") { SummaryPreviewPair(model: running()).preferredColorScheme(.light) }
#Preview("Running - dark") { SummaryPreviewPair(model: running()).preferredColorScheme(.dark) }
#Preview("Failed - light") { SummaryPreviewPair(model: failed()).preferredColorScheme(.light) }
#Preview("Failed - dark") { SummaryPreviewPair(model: failed()).preferredColorScheme(.dark) }
#Preview("Cancelled - light") { SummaryPreviewPair(model: cancelled()).preferredColorScheme(.light) }
#Preview("Cancelled - dark") { SummaryPreviewPair(model: cancelled()).preferredColorScheme(.dark) }
#Preview("No exit code - light") { SummaryPreviewPair(model: noExit()).preferredColorScheme(.light) }
#Preview("No exit code - dark") { SummaryPreviewPair(model: noExit()).preferredColorScheme(.dark) }
#Preview("Missing metrics, no files - light") { SummaryPreviewPair(model: bare()).preferredColorScheme(.light) }
#Preview("Missing metrics, no files - dark") { SummaryPreviewPair(model: bare()).preferredColorScheme(.dark) }
#Preview("Twelve files - light") { SummaryPreviewPair(model: manyFiles()).preferredColorScheme(.light) }
#Preview("Twelve files - dark") { SummaryPreviewPair(model: manyFiles()).preferredColorScheme(.dark) }
#Preview("Loading - light") { SummaryPreviewPair(model: .empty).preferredColorScheme(.light) }
#Preview("Loading - dark") { SummaryPreviewPair(model: .empty).preferredColorScheme(.dark) }
#endif
