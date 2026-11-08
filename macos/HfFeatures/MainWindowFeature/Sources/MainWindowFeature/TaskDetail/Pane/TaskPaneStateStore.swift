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
        /// The person's own tab choice; `nil` means no choice, so the applied default decides.
        var selectedTab: Tab?
        /// The tab resolved with the open default on first show (`changes` for a terminal status, `events`
        /// otherwise), `nil` until it was resolved.
        var appliedDefaultTab: Tab?
        var expandedGroups: Set<FactsGroup> = []
        /// Whether the first-show default opens the pane at split widths; `nil` until a default was resolved.
        /// Kept so a conversation first shown closed (for example while running) stays closed when revisited.
        var appliedDefaultOpensAtSplit: Bool?
        /// Whether the Events tab's nested Technical info is expanded. It changes the document height the
        /// saved Events offset is relative to, so it persists with it.
        var technicalInfoExpanded = false
    }

    // MARK: - Properties

    /// The most conversations remembered at once.
    static let capacity = 64

    private var entries: [String: Entry] = [:]
    /// Least recently used first. Not observed: touching a key must not invalidate views.
    @ObservationIgnored private var recency: [String] = []
    /// The Events tab's last vertical scroll offset per conversation. Not observed: the pane records it on
    /// every scroll step and no view renders from it. Bounded on its own, so a write never creates a recency
    /// entry, touches `entries` or evicts a conversation's choices.
    @ObservationIgnored private var eventsOffsets: [String: CGFloat] = [:]
    /// Offset keys, least recently written first.
    @ObservationIgnored private var offsetOrder: [String] = []

    // MARK: - Lifecycle

    /// Creates an empty store.
    init() {}

    // MARK: - Reading

    /// The pane's open choice, `noChoice` when none was made.
    func openChoice(for conversationID: String) -> OpenChoice { entries[conversationID]?.openChoice ?? .noChoice }

    /// The tab a person chose, `nil` when none was chosen.
    func selectedTab(for conversationID: String) -> Tab? { entries[conversationID]?.selectedTab }

    /// The tab resolved on first show, `nil` when none was resolved or the entry was evicted.
    func appliedDefaultTab(for conversationID: String) -> Tab? { entries[conversationID]?.appliedDefaultTab }

    /// The expanded facts groups, none when nothing was expanded.
    func expandedGroups(for conversationID: String) -> Set<FactsGroup> { entries[conversationID]?.expandedGroups ?? [] }

    /// Whether the store holds an entry for the conversation.
    func hasEntry(for conversationID: String) -> Bool { entries[conversationID] != nil }

    /// The remembered conversation ids, least recently used first.
    var rememberedIDs: [String] { recency }

    /// The Events tab's last scroll offset, `nil` when none was recorded.
    func eventsScrollOffset(for conversationID: String) -> CGFloat? { eventsOffsets[conversationID] }

    /// The default applied on first show, `nil` when none was resolved or the entry was evicted.
    func appliedDefault(for conversationID: String) -> Bool? { entries[conversationID]?.appliedDefaultOpensAtSplit }

    /// Whether Technical info is expanded, collapsed when nothing was recorded.
    func technicalInfoExpanded(for conversationID: String) -> Bool { entries[conversationID]?.technicalInfoExpanded ?? false }

    // MARK: - Writing

    /// Records the pane's open choice. An unchanged value writes nothing.
    func setOpenChoice(_ choice: OpenChoice, for conversationID: String) {
        set(\.openChoice, choice, for: conversationID)
    }

    /// Records the selected tab. An unchanged value writes nothing.
    func setSelectedTab(_ tab: Tab, for conversationID: String) {
        set(\.selectedTab, tab, for: conversationID)
    }

    /// Records the tab resolved on first show. Written once per conversation by the pane.
    func setAppliedDefaultTab(_ tab: Tab, for conversationID: String) {
        set(\.appliedDefaultTab, tab, for: conversationID)
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

    /// Records the Events tab's scroll offset. It is a reading anchor, so it never invalidates a view.
    func setEventsScrollOffset(_ offset: CGFloat, for conversationID: String) {
        eventsOffsets[conversationID] = offset
        // Least recently written last: a rewrite moves the key to the back.
        if offsetOrder.last != conversationID {
            if let index = offsetOrder.firstIndex(of: conversationID) { offsetOrder.remove(at: index) }
            offsetOrder.append(conversationID)
        }
        while offsetOrder.count > Self.capacity { eventsOffsets.removeValue(forKey: offsetOrder.removeFirst()) }
    }

    /// Records the default applied on first show. Written once per conversation by the pane.
    func setAppliedDefault(_ opensAtSplit: Bool, for conversationID: String) {
        set(\.appliedDefaultOpensAtSplit, opensAtSplit, for: conversationID)
    }

    /// Records whether Technical info is expanded. An unchanged value writes nothing.
    func setTechnicalInfoExpanded(_ expanded: Bool, for conversationID: String) {
        set(\.technicalInfoExpanded, expanded, for: conversationID)
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
            remember(id)
        }
        touch(id)
    }

    /// Adds the conversation to the recency list when absent and evicts the least recently used past capacity.
    private func remember(_ id: String) {
        if !recency.contains(id) { recency.append(id) }
        while recency.count > Self.capacity {
            entries.removeValue(forKey: recency.removeFirst())
        }
    }
}
