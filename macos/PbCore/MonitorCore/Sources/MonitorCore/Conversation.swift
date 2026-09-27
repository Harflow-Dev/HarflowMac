import Foundation

/// A resume chain: tasks connected by `parent_task_id`, oldest to newest. Piece 7 of the Monitor
/// architecture plan — a follow-up sent to a finished task continues the same conversation instead
/// of starting a new one from the Monitor's point of view. Resume ancestry may branch (an older,
/// already-resumed member can itself be resumed again later), so this is the connected set under
/// `parent_task_id`, not necessarily a linear chain.
public struct Conversation: Equatable, Identifiable, Sendable {
    /// Oldest to newest (`Lineage.startedAscending`, tie broken by task id). Never empty: grouping
    /// always produces at least the task itself.
    public let members: [TaskInfo]

    public init(members: [TaskInfo]) {
        self.members = members
    }

    /// The conversation's identity: its earliest member, stable across every later follow-up.
    public var id: String { members[0].taskID }
    /// The earliest member — its title names the conversation, and its own `spawned_by`/ancestors
    /// place the conversation in the sidebar's tree (Review round 1, item 2).
    public var first: TaskInfo { members[0] }
    /// The newest member — status, placement, age, and every action (send/cancel/take over/copy
    /// resume command/continue) target this task (settled Design point 6).
    public var current: TaskInfo { members[members.count - 1] }
}

/// A conversation and the sub-task trees any of its members started (`spawned_by`) — the
/// conversation-level analogue of `TaskNode` for the sidebar's Running/Recent tree (piece 7).
/// Parallel groups stay task-level (Review round 1, item 3) and so are built from `TaskNode`/
/// `Lineage.sections(_:matches:)` exactly as before.
public struct ConversationNode: Equatable, Identifiable, Sendable {
    public var id: String { conversation.id }
    public let conversation: Conversation
    public let children: [ConversationNode]

    public init(conversation: Conversation, children: [ConversationNode]) {
        self.conversation = conversation
        self.children = children
    }

    /// A conversation with any running member — not only its current one, in case disk ever
    /// disagrees — or any running descendant stays in Running even once its own current task has
    /// settled (Review round 1, item 5's "descendant-aware" placement).
    public var anyRunning: Bool {
        conversation.members.contains { $0.status.isRunning } || children.contains(where: \.anyRunning)
    }

    public var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }

    public func flattened(depth: Int = 0) -> [(node: ConversationNode, indent: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }

    /// `TaskNode.flattenedWithGuides()`'s conversation-level twin — see `TreeGuides` for the shared
    /// pure computation (settled plan's "guides over conversation nodes").
    public func flattenedWithGuides(depth: Int = 0) -> [(node: ConversationNode, indent: Int, guides: [TreeGuide])] {
        TreeGuides.flattenedWithGuides(self, depth: depth, children: { $0.children })
    }
}

/// The guide computation `TaskNode.flattenedWithGuides()` and `ConversationNode.flattenedWithGuides()`
/// share: one `TreeGuide` per ancestor level (a continuation line or a blank column), followed by
/// this row's own connector — pure over whichever node type's own `children`, so it is written once.
enum TreeGuides {
    static func flattenedWithGuides<Node>(
        _ root: Node, depth: Int, children: (Node) -> [Node]
    ) -> [(node: Node, indent: Int, guides: [TreeGuide])] {
        rows(root, depth: depth, ancestorGuides: [], isLastChild: nil, children: children)
    }

    private static func rows<Node>(
        _ node: Node, depth: Int, ancestorGuides: [TreeGuide], isLastChild: Bool?, children: (Node) -> [Node]
    ) -> [(node: Node, indent: Int, guides: [TreeGuide])] {
        let guides = isLastChild.map { ancestorGuides + [$0 ? .last : .branch] } ?? []
        var rows: [(node: Node, indent: Int, guides: [TreeGuide])] = [(node, depth, guides)]
        let kids = children(node)
        let descendantGuides = isLastChild.map { ancestorGuides + [$0 ? .blank : .continuation] } ?? []
        let lastIndex = kids.count - 1
        for (index, child) in kids.enumerated() {
            rows += Self.rows(child, depth: depth + 1, ancestorGuides: descendantGuides, isLastChild: index == lastIndex, children: children)
        }
        return rows
    }
}

/// The sidebar's Running/Recent trees, built from conversations rather than individual tasks.
public struct ConversationSections: Equatable, Sendable {
    public var running: [ConversationNode] = []
    public var recent: [ConversationNode] = []
    public init() {}
}

/// A one-shot index over `[TaskInfo]`'s conversations (`Lineage.conversations(_:)`'s grouping) and
/// the parent/child map used to place them in the sidebar's tree — built ONCE from a listing and
/// reused for every conversation-lineage query one recompute needs (Monitor piece 11 / Plan review
/// round 1, item 1), instead of each of `Lineage.conversationSections(_:matches:)`/
/// `conversationAncestors(of:in:)`/`conversationChildren(of:in:)`/`conversationID(of:in:)`/
/// `conversation(containing:in:)` rebuilding the whole conversation tree from scratch on every call.
/// Measured: `SidebarVM`'s per-matching-task `forcedExpandedIDs` loop cost 0.36s/recompute on a
/// 532-task real listing with a backend tab selected (113 matches) — O(n²) over the number of
/// matching tasks, each rebuild being an O(n) tree construction. Those four `Lineage` statics above
/// become thin wrappers over a fresh one-shot `ConversationIndex` — unchanged behaviour/complexity
/// for a single call — while `SidebarVM` builds one per `recompute()` and reuses it.
///
/// A conversation's parent is the spawned_by of its FIRST member only, mapped to that spawner's own
/// conversation — never any other member's `spawned_by`, which is exactly what keeps a branching
/// resume from looping (e.g. A spawns X, X resumes A as B: B's own `spawned_by` == X is simply never
/// consulted, so conversation(A,B) cannot end up parented under X even though X is correctly
/// attached as ITS child). A defensive cycle-break — the same shape as `Lineage.parentMap`'s — still
/// runs afterwards, since disk is not trusted.
public struct ConversationIndex: Sendable {
    private let byID: [String: Conversation]
    private let memberToConversationID: [String: String]
    private let parent: [String: String]
    private let children: [String: [String]]

    public init(_ tasks: [TaskInfo]) {
        let convs = Lineage.conversations(tasks)
        var byID: [String: Conversation] = [:]
        var memberToConversationID: [String: String] = [:]
        for conv in convs {
            byID[conv.id] = conv
            for member in conv.members where memberToConversationID[member.taskID] == nil {
                memberToConversationID[member.taskID] = conv.id
            }
        }
        self.byID = byID
        self.memberToConversationID = memberToConversationID

        var parent: [String: String] = [:]
        for conv in convs {
            guard let spawner = conv.first.spawnedBy,
                  let spawnerConv = memberToConversationID[spawner],
                  spawnerConv != conv.id else { continue }
            parent[conv.id] = spawnerConv
        }
        for conv in convs {
            var seen: Set<String> = [conv.id]
            var cursor = parent[conv.id]
            while let current = cursor {
                if seen.contains(current) {
                    parent[conv.id] = nil
                    break
                }
                seen.insert(current)
                cursor = parent[current]
            }
        }
        self.parent = parent
        var children: [String: [String]] = [:]
        for (child, parentID) in parent { children[parentID, default: []].append(child) }
        self.children = children
    }

    /// The id of the conversation `taskID` belongs to (its earliest member) — falls back to `taskID`
    /// itself when it is not present in the indexed listing at all.
    public func conversationID(of taskID: String) -> String {
        memberToConversationID[taskID] ?? taskID
    }

    /// The whole conversation `taskID` belongs to, resolved from any of its members.
    public func conversation(containing taskID: String) -> Conversation? {
        memberToConversationID[taskID].flatMap { byID[$0] }
    }

    /// Root-first ancestor conversations above the one containing `taskID`.
    public func ancestors(ofConversationContaining taskID: String) -> [Conversation] {
        let id = conversationID(of: taskID)
        var chain: [Conversation] = []
        var cursor = parent[id]
        while let current = cursor, let conv = byID[current] {
            chain.insert(conv, at: 0)
            cursor = parent[current]
        }
        return chain
    }

    /// `conversationID`'s own children in the sidebar's tree.
    public func children(of conversationID: String) -> [Conversation] {
        (children[conversationID] ?? []).compactMap { byID[$0] }
    }

    /// Build the sidebar's Running/Recent trees from the indexed conversations. `matches` is the
    /// search/backend filter — a conversation is kept when any of its members, or any node beneath
    /// it, matches.
    ///
    /// `.group` is checked here, and only here (Codex review round 1, finding 1) — exactly where
    /// the old task-level `Lineage.sections(_:matches:)` checked it too: a ROOT (no parent)
    /// conversation whose FIRST member carries a `.group` is a Parallel column, not a Running/Recent
    /// entry, and is skipped entirely (Parallel's own listing, `Lineage.sections(_:matches:).parallel`,
    /// shows it and its own children unchanged); a NON-root grouped conversation still nests
    /// wherever its real spawner placed it, same as any other descendant.
    public func sections(matches: (TaskInfo) -> Bool = { _ in true }) -> ConversationSections {
        func node(_ id: String) -> ConversationNode {
            let conv = byID[id]!
            let kids = (children[id] ?? [])
                .compactMap { byID[$0] }
                .sorted { Lineage.startedAscending($0.first, $1.first) }
                .map { node($0.id) }
            return ConversationNode(conversation: conv, children: kids)
        }
        func keep(_ node: ConversationNode) -> Bool {
            node.conversation.members.contains(where: matches) || node.children.contains(where: keep)
        }

        var sections = ConversationSections()
        for (id, conv) in byID where parent[id] == nil && conv.first.group == nil {
            let tree = node(conv.id)
            guard keep(tree) else { continue }
            if tree.anyRunning { sections.running.append(tree) } else { sections.recent.append(tree) }
        }
        sections.running.sort { Lineage.startedDescending($0.conversation.current, $1.conversation.current) }
        sections.recent.sort { Lineage.startedDescending($0.conversation.current, $1.conversation.current) }
        return sections
    }
}

extension Lineage {
    /// The `parent_task_id` parent a task is a follow-up to: present only when that parent is known
    /// and the link is not a cycle — the same defences as `parentMap`, since disk is not trusted.
    private static func parentTaskMap(_ tasks: [TaskInfo]) -> [String: String] {
        let ids = Set(tasks.map(\.taskID))
        var parent: [String: String] = [:]
        for task in tasks {
            if let parentID = task.parentTaskID, parentID != task.taskID, ids.contains(parentID) { parent[task.taskID] = parentID }
        }
        for task in tasks {
            var seen: Set<String> = [task.taskID]
            var cursor = parent[task.taskID]
            while let current = cursor {
                if seen.contains(current) {
                    parent[task.taskID] = nil
                    break
                }
                seen.insert(current)
                cursor = parent[current]
            }
        }
        return parent
    }

    /// Groups `tasks` into conversations: the connected set under `parent_task_id` (Review round 1,
    /// item 2), each ordered oldest to newest. A task whose `parent_task_id` parent is missing
    /// (retention, or simply absent) starts its own, single-member conversation.
    public static func conversations(_ tasks: [TaskInfo]) -> [Conversation] {
        let parent = parentTaskMap(tasks)
        var componentOf: [String: String] = [:]
        func component(of id: String) -> String {
            if let cached = componentOf[id] { return cached }
            var chain = [id]
            var cursor = id
            while let parentID = parent[cursor] {
                cursor = parentID
                chain.append(cursor)
            }
            for node in chain { componentOf[node] = cursor }
            return cursor
        }
        var groups: [String: [TaskInfo]] = [:]
        for task in tasks { groups[component(of: task.taskID), default: []].append(task) }
        return groups.values.map { Conversation(members: $0.sorted(by: startedAscending)) }
    }

    /// The id of the conversation `taskID` belongs to (its earliest member) — used to normalise a
    /// selection made on any member back to the row that represents its whole conversation (Review
    /// round 1, item 5's selection normalisation). Falls back to `taskID` itself when it is not
    /// present in `tasks` at all, so a stale/unknown id still normalises to something stable. A thin
    /// wrapper over a fresh `ConversationIndex` — see `conversationSections(_:matches:)`'s doc.
    public static func conversationID(of taskID: String, in tasks: [TaskInfo]) -> String {
        ConversationIndex(tasks).conversationID(of: taskID)
    }

    /// The whole conversation `taskID` belongs to, resolved from any of its members (settled
    /// Design point 6: "TaskDetailVM for any member id resolves the whole conversation"). A thin
    /// wrapper over a fresh `ConversationIndex` — see `conversationSections(_:matches:)`'s doc.
    public static func conversation(containing taskID: String, in tasks: [TaskInfo]) -> Conversation? {
        ConversationIndex(tasks).conversation(containing: taskID)
    }

    /// Build the sidebar's Running/Recent trees from conversations (piece 7). `matches` is the
    /// search/backend filter — a conversation is kept when any of its members, or any node beneath
    /// it, matches.
    ///
    /// A thin wrapper over a fresh, one-shot `ConversationIndex` (Monitor piece 11) — same
    /// behaviour and complexity as before for a single call. `SidebarVM` builds one `ConversationIndex`
    /// per `recompute()` instead and calls `sections(matches:)` on it directly, so its own several
    /// conversation-lineage queries per recompute share one build rather than each rebuilding the
    /// whole conversation tree from scratch (measured: 0.36s/recompute on a 532-task real listing
    /// with a backend tab selected, O(n²) over the number of matching tasks).
    public static func conversationSections(_ tasks: [TaskInfo], matches: (TaskInfo) -> Bool = { _ in true }) -> ConversationSections {
        ConversationIndex(tasks).sections(matches: matches)
    }

    /// Root-first ancestor conversations above the one containing `taskID` — the conversation
    /// analogue of `ancestors(of:in:)`, used by the sidebar's collapse/reveal (piece 7). A thin
    /// wrapper over a fresh `ConversationIndex` — see `conversationSections(_:matches:)`'s doc.
    public static func conversationAncestors(of taskID: String, in tasks: [TaskInfo]) -> [Conversation] {
        ConversationIndex(tasks).ancestors(ofConversationContaining: taskID)
    }

    /// The conversation `conversationID`'s own children in the sidebar's tree (piece 7). A thin
    /// wrapper over a fresh `ConversationIndex` — see `conversationSections(_:matches:)`'s doc.
    public static func conversationChildren(of conversationID: String, in tasks: [TaskInfo]) -> [Conversation] {
        ConversationIndex(tasks).children(of: conversationID)
    }

    /// The exact scope `tasks.py`'s cancel cascade computes for `taskID` (`_cascade_targets`/
    /// `lineage.lineage_closure`, ~tasks.py:1817 — Review round 2): the task itself, every
    /// descendant reachable by following `spawned_by`, and every task whose `root_task_id` names it
    /// directly (not transitively expanded further — matching the backend exactly). A thin wrapper
    /// over a fresh `LineageIndex` (Monitor piece 11) — see `Lineage.ancestors(of:in:)`'s doc.
    public static func cancelScope(of taskID: String, in tasks: [TaskInfo]) -> Set<String> {
        LineageIndex(tasks).cancelScope(of: taskID)
    }

    /// The deterministic survivor rule for "retention while open" (Review round 1, item 4 / Codex
    /// review round 1, finding 3): the OLDEST still-present member of `candidates`
    /// (`started_at` ascending, tie broken by task id — `startedAscending`, the same tie-break
    /// every other ordering in this file uses). Shared by `TaskDetailVM` and `SidebarVM` so a
    /// branching prune (A resumed to both B and C, then A itself is pruned) is resolved to the same
    /// id by both screens — never `Set.first`, which has no defined order. `nil` when none of
    /// `candidates` is present in `tasks` at all.
    public static func oldestSurvivor(among candidates: Set<String>, in tasks: [TaskInfo]) -> String? {
        let byID = Dictionary(tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        return candidates.compactMap { byID[$0] }.sorted(by: startedAscending).first?.taskID
    }
}
