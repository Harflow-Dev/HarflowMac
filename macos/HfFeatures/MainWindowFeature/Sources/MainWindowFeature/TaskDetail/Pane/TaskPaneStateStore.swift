//
//  TaskPaneStateStore.swift
//  MainWindowFeature
//
//  Per-conversation state of the task screen's side pane. A task view's `@State` does not survive the
//  coordinator's `.id(conversationID)` reset, so the choices live here, one instance per main window.
//

import Foundation
import Observation

// MARK: - TaskPaneStateStore

/// Remembers, per conversation, whether the pane is open, which tab it shows and which facts groups
/// are expanded. Entries are bounded: the least recently used one is dropped past `capacity`.
///
/// All entries share one observed dictionary, so a write for one conversation invalidates readers of any
/// conversation; that is acceptable while only the standalone mount reads it. An entry can be evicted while
/// its conversation is still shown, so the consumer must `touch` on show and keep the default it applied in
/// its own view state rather than re-deriving it from `noChoice`.
@MainActor
@Observable
final class TaskPaneStateStore {

    // MARK: - Types

    /// Whether the user has opened or closed the pane. `noChoice` lets the screen apply its own default.
    enum OpenChoice: Equatable, Sendable {
        case noChoice, open, closed
    }

    /// A pane tab.
    enum Tab: Equatable, Sendable, CaseIterable {
        case changes, artifacts, events
    }

    /// A collapsible group in the Events tab's facts list.
    enum FactsGroup: Hashable, Sendable, CaseIterable {
        case task, enforcement, notices, continuity
        /// Interim group for reported cost, usage, permission denials and Files edited, pending design
        /// classification (coordinator ruling D-USAGE).
        case usage
    }

    /// The stored choices for one conversation.
    struct Entry: Equatable, Sendable {
        var openChoice: OpenChoice = .noChoice
        var selectedTab: Tab = .changes
        var expandedGroups: Set<FactsGroup> = []
    }

    // MARK: - Properties

    /// The most conversations remembered at once.
    static let capacity = 64

    private var entries: [String: Entry] = [:]
    /// Least recently used first. Not observed: touching a key must not invalidate views.
    @ObservationIgnored private var recency: [String] = []

    // MARK: - Lifecycle

    /// Creates an empty store.
    init() {}

    // MARK: - Reading

    /// The pane's open choice, `noChoice` when none was made.
    func openChoice(for conversationID: String) -> OpenChoice { entries[conversationID]?.openChoice ?? .noChoice }

    /// The selected tab, `changes` when none was chosen.
    func selectedTab(for conversationID: String) -> Tab { entries[conversationID]?.selectedTab ?? .changes }

    /// The expanded facts groups, none when nothing was expanded.
    func expandedGroups(for conversationID: String) -> Set<FactsGroup> { entries[conversationID]?.expandedGroups ?? [] }

    /// Whether the store holds an entry for the conversation.
    func hasEntry(for conversationID: String) -> Bool { entries[conversationID] != nil }

    /// The remembered conversation ids, least recently used first.
    var rememberedIDs: [String] { recency }

    // MARK: - Writing

    /// Records the pane's open choice. An unchanged value writes nothing.
    func setOpenChoice(_ choice: OpenChoice, for conversationID: String) {
        set(\.openChoice, choice, for: conversationID)
    }

    /// Records the selected tab. An unchanged value writes nothing.
    func setSelectedTab(_ tab: Tab, for conversationID: String) {
        set(\.selectedTab, tab, for: conversationID)
    }

    /// Records the full set of expanded facts groups. An unchanged value writes nothing.
    func setExpandedGroups(_ groups: Set<FactsGroup>, for conversationID: String) {
        set(\.expandedGroups, groups, for: conversationID)
    }

    /// Expands or collapses one facts group.
    func setGroup(_ group: FactsGroup, expanded: Bool, for conversationID: String) {
        var groups = expandedGroups(for: conversationID)
        if expanded { groups.insert(group) } else { groups.remove(group) }
        setExpandedGroups(groups, for: conversationID)
    }

    /// Marks the conversation as most recently used. Does nothing for a conversation without an entry.
    func touch(_ conversationID: String) {
        guard let index = recency.firstIndex(of: conversationID), index != recency.count - 1 else { return }
        recency.remove(at: index)
        recency.append(conversationID)
    }

    // MARK: - Private

    /// Writes one field, creating the entry only when the value differs from what is stored (or the
    /// default), then marks the conversation most recently used and evicts past capacity.
    private func set<Value: Equatable>(_ keyPath: WritableKeyPath<Entry, Value>, _ value: Value, for id: String) {
        var entry = entries[id] ?? Entry()
        if entry[keyPath: keyPath] != value {
            entry[keyPath: keyPath] = value
            entries[id] = entry
            if !recency.contains(id) { recency.append(id) }
            while recency.count > Self.capacity {
                entries.removeValue(forKey: recency.removeFirst())
            }
        }
        touch(id)
    }
}
