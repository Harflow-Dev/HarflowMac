//
//  ActivityRow.swift
//  MainWindowFeature
//
//  The Activity tab's own row model: MonitorCore's `ConversationTimelineRow`s with adjacent tool
//  calls folded into cards. `ActivityRowsBuilder` produces them; the raw rows stay on
//  `TimelinePaneModel.rows` (the inspector's step count reads those, not these).
//

import Foundation
import MonitorCore
import PbUI

// MARK: - ActivityRow

/// One entry of the Activity feed: a row rendered on its own, or a card folding adjacent tool calls.
enum ActivityRow: Equatable, Identifiable {
    case single(ConversationTimelineRow)
    case toolGroup(ToolGroup)

    var id: String {
        switch self {
        case .single(let row): row.id
        case .toolGroup(let group): group.id
        }
    }
}

// MARK: - ToolBucket

/// The kind of tool call a card folds. Edits and writes have no bucket: they stay individual rows
/// with their diff preview.
enum ToolBucket: Equatable, Sendable {
    case read, search, shell
    /// MCP, web and any category the Monitor does not know.
    case other

    /// `nil` for `edit` and `write`, which are never grouped.
    init?(category: String) {
        switch category {
        case "read": self = .read
        case "search": self = .search
        case "shell": self = .shell
        case "edit", "write": return nil
        default: self = .other
        }
    }

    var iconName: String {
        switch self {
        case .read: "doc.text"
        case .search: "magnifyingglass"
        case .shell: "terminal"
        case .other: "wrench"
        }
    }
}

// MARK: - ToolGroupMember

/// One tool call inside a card: the canonical call/result pair of its own timeline row.
struct ToolGroupMember: Equatable, Identifiable {
    let id: String
    let call: TaskEvent.ToolCall
    let result: TaskEvent.ToolResult?
    let timestamp: Date?
    let live: Bool

    /// Still waiting for a result in the running turn (the card shows a spinner for it).
    var isPending: Bool { result == nil && live }
    var isFailed: Bool { result.map { !$0.ok } ?? false }
}

// MARK: - ToolGroup

/// A card folding adjacent tool calls of one bucket. Everything the card shows is derived once,
/// when the builder closes the group, so rendering it is free.
struct ToolGroup: Equatable, Identifiable {
    /// The first member's row id: stable while the group grows, so expansion state can key off it.
    let id: String
    let taskID: String
    let bucket: ToolBucket
    let members: [ToolGroupMember]
    /// "Read 3 files · 1 failed", "Ran 2 commands", …
    let summary: String
    /// The search terms of a search card, when any could be read from the calls.
    let subtitle: String?
    let firstAt: Date?
    let lastAt: Date?
    let isRunning: Bool
    /// File names of a read card's distinct paths, at most `ToolGroup.pillLimit`.
    let pillNames: [String]
    let overflowCount: Int

    static let pillLimit = 9

    init(id: String, taskID: String, bucket: ToolBucket, members: [ToolGroupMember]) {
        self.id = id
        self.taskID = taskID
        self.bucket = bucket
        self.members = members
        let paths = Self.distinctPaths(members)
        self.summary = Self.summary(bucket: bucket, members: members, distinctPathCount: paths.count)
        self.subtitle = bucket == .search ? Self.searchSubtitle(members) : nil
        self.firstAt = members.first?.timestamp
        self.lastAt = members.last?.timestamp
        self.isRunning = members.contains(where: \.isPending)
        let names = bucket == .read ? paths.map { ($0 as NSString).lastPathComponent } : []
        self.pillNames = Array(names.prefix(Self.pillLimit))
        self.overflowCount = max(0, names.count - Self.pillLimit)
    }

    /// "00:25 – 01:09" from the first and last member timestamps, offset from the conversation's
    /// start; clock times when the start is unknown; a single time when both ends read the same.
    func timeRangeText(start: Date?) -> String {
        func label(_ date: Date?) -> String { start != nil ? Format.offset(date, from: start) : Format.time(date) }
        let first = label(firstAt)
        let last = label(lastAt)
        if first.isEmpty { return last }
        return first == last || last.isEmpty ? first : "\(first) – \(last)"
    }

    // MARK: Wording

    private static func summary(bucket: ToolBucket, members: [ToolGroupMember], distinctPathCount: Int) -> String {
        let count = members.count
        switch bucket {
        case .read:
            let failed = members.filter(\.isFailed).count
            let base = distinctPathCount > 0
                ? "Read \(distinctPathCount) \(distinctPathCount == 1 ? "file" : "files")"
                : "\(count) \(count == 1 ? "read" : "reads")"
            return failed > 0 ? "\(base) · \(failed) failed" : base
        case .search: return "Searched \(count) \(count == 1 ? "time" : "times")"
        case .shell: return "Ran \(count) \(count == 1 ? "command" : "commands")"
        case .other: return "Used \(count) \(count == 1 ? "tool" : "tools")"
        }
    }

    /// Known paths only, in order of first appearance.
    private static func distinctPaths(_ members: [ToolGroupMember]) -> [String] {
        var seen: Set<String> = []
        var paths: [String] = []
        for member in members {
            guard let path = member.call.path, !path.isEmpty, seen.insert(path).inserted else { continue }
            paths.append(path)
        }
        return paths
    }

    private static func searchSubtitle(_ members: [ToolGroupMember]) -> String? {
        var seen: Set<String> = []
        var terms: [String] = []
        for member in members {
            guard let term = searchTerm(member.call.inputPreview), seen.insert(term).inserted else { continue }
            terms.append(term)
        }
        guard !terms.isEmpty else { return nil }
        let shown = terms.prefix(3).joined(separator: ", ")
        return terms.count > 3 ? "\(shown) +\(terms.count - 3) more" : shown
    }

    /// The `pattern` or `query` of a call whose input preview parses as a JSON object; `nil` for a
    /// preview that is truncated, not JSON, or carries neither key.
    static func searchTerm(_ inputPreview: String) -> String? {
        guard let object = JSONValue.parse(Data(inputPreview.utf8))?.objectValue else { return nil }
        let raw = object["pattern"]?.stringValue ?? object["query"]?.stringValue
        let term = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return term?.isEmpty == false ? term : nil
    }
}
