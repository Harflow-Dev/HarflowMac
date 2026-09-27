import Foundation

/// A task and the sub-tasks it started (`spawned_by`), for the sidebar's tree.
public struct TaskNode: Equatable, Identifiable, Sendable {
    public var id: String { task.taskID }
    public let task: TaskInfo
    public let children: [TaskNode]

    public var anyRunning: Bool { task.status.isRunning || children.contains(where: \.anyRunning) }
    public var descendantCount: Int { children.reduce(0) { $0 + 1 + $1.descendantCount } }

    public func flattened(depth: Int = 0) -> [(node: TaskNode, indent: Int)] {
        [(self, depth)] + children.flatMap { $0.flattened(depth: depth + 1) }
    }

    /// `flattened(depth:)` plus per-row tree guides for the sidebar's collapsible tree: one
    /// `TreeGuide` per ancestor level (root ancestor first, a continuation line or a blank column),
    /// followed by this row's own connector (`.branch`/`.last`) — empty for a root row (depth 0),
    /// which draws no connector of its own. Pure over `children`; no view code.
    public func flattenedWithGuides(depth: Int = 0) -> [(node: TaskNode, indent: Int, guides: [TreeGuide])] {
        TreeGuides.flattenedWithGuides(self, depth: depth, children: { $0.children })
    }
}

/// One column in a sidebar row's tree-guide gutter: an ancestor-level continuation line, a blank
/// column (no later sibling at that level), or this row's own connector glyph.
public enum TreeGuide: Equatable, Sendable {
    /// An ancestor column: a later sibling exists at that level, so the vertical line continues
    /// through it.
    case continuation
    /// An ancestor column: no later sibling at that level, so nothing draws.
    case blank
    /// This row's own connector: a later sibling follows among this row's own siblings (├).
    case branch
    /// This row's own connector: this row is the last child among its own siblings (└).
    case last
}

/// Tasks sharing a `group` label: the columns of the Parallel view. Only the group's top-level
/// members are columns; a member's own sub-tasks (which inherit the label) stay under it.
public struct ParallelGroup: Equatable, Identifiable, Sendable {
    public var id: String { "group:\(name)" }
    public let name: String
    public let members: [TaskNode]

    public var total: Int { members.count }
    public var doneCount: Int { members.filter { $0.task.status.isTerminal }.count }
    public var anyRunning: Bool { members.contains(where: \.anyRunning) }
    public var startedAt: Date? { members.compactMap(\.task.startedAt).min() }
}

public struct SidebarSections: Equatable, Sendable {
    public var running: [TaskNode] = []
    public var parallel: [ParallelGroup] = []
    public var recent: [TaskNode] = []
    public init() {}
}

/// A one-shot index over `[TaskInfo]`'s task-level lineage — built ONCE from a listing and reused
/// for every `ancestors`/`children`/`siblings`/`cancelScope` query one recompute needs (Monitor
/// piece 11 / Plan review round 1, item 2), instead of `Lineage.ancestors(of:in:)`/`children(of:in:)`/
/// `siblings(of:in:)`/`cancelScope(of:in:)` each rebuilding their own map from `tasks` on every call.
/// `TaskDetailVM.recompute()` calls several of these per conversation member per publication; this
/// lets a caller build the shared maps once and reuse them across that whole recompute.
///
/// `ancestors`/`children`/`siblings` are built over the SAME `spawned_by` parent map
/// `Lineage.parentMap(_:)` computes (known ids only, cycle-broken). `cancelScope` deliberately uses
/// a SEPARATE, unfiltered `spawned_by` child map (Review round 2's exact match of `tasks.py`'s
/// cascade): it never drops a link just because its spawner is missing from `tasks`, and needs no
/// cycle-break since its own frontier walk already guards against revisiting a target. Semantics
/// preserved exactly — each query returns exactly what the pre-piece-11 per-call `Lineage` statics
/// did.
public struct LineageIndex: Sendable {
    private let byID: [String: TaskInfo]
    private let parent: [String: String]
    private let childrenByParent: [String: [TaskInfo]]
    private let spawnedByChildren: [String: [String]]
    private let byRootTaskID: [String: [String]]

    public init(_ tasks: [TaskInfo]) {
        byID = Dictionary(tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        let parent = Lineage.parentMap(tasks)
        self.parent = parent

        var childrenByParent: [String: [TaskInfo]] = [:]
        for (child, parentID) in parent {
            if let task = byID[child] { childrenByParent[parentID, default: []].append(task) }
        }
        for key in childrenByParent.keys { childrenByParent[key]?.sort(by: Lineage.startedAscending) }
        self.childrenByParent = childrenByParent

        var spawnedByChildren: [String: [String]] = [:]
        for task in tasks {
            if let spawner = task.spawnedBy { spawnedByChildren[spawner, default: []].append(task.taskID) }
        }
        self.spawnedByChildren = spawnedByChildren

        var byRootTaskID: [String: [String]] = [:]
        for task in tasks {
            if let root = task.rootTaskID { byRootTaskID[root, default: []].append(task.taskID) }
        }
        self.byRootTaskID = byRootTaskID
    }

    /// Root first, direct parent last — the breadcrumb above a sub-task.
    public func ancestors(of taskID: String) -> [TaskInfo] {
        var chain: [TaskInfo] = []
        var cursor = parent[taskID]
        while let id = cursor, let task = byID[id] {
            chain.insert(task, at: 0)
            cursor = parent[id]
        }
        return chain
    }

    public func children(of taskID: String) -> [TaskInfo] {
        childrenByParent[taskID] ?? []
    }

    /// The current parent's other children (F4-38's lineage list) — every child of the nearest
    /// ancestor, current task included, or none for a root task.
    public func siblings(of taskID: String) -> [TaskInfo] {
        guard let parentID = ancestors(of: taskID).last?.taskID else { return [] }
        return children(of: parentID)
    }

    /// The exact scope `tasks.py`'s cancel cascade computes for `taskID` (`_cascade_targets`/
    /// `lineage.lineage_closure`, ~tasks.py:1817 — Review round 2): the task itself, every
    /// descendant reachable by following `spawned_by`, and every task whose `root_task_id` names it
    /// directly (not transitively expanded further — matching the backend exactly).
    public func cancelScope(of taskID: String) -> Set<String> {
        var targets: Set<String> = [taskID]
        var frontier = [taskID]
        while let current = frontier.popLast() {
            for child in spawnedByChildren[current] ?? [] where !targets.contains(child) {
                targets.insert(child)
                frontier.append(child)
            }
        }
        for id in byRootTaskID[taskID] ?? [] { targets.insert(id) }
        return targets
    }
}

public enum Lineage {
    /// The parent a task is drawn under: its `spawned_by`, when that task is known and the link
    /// is not a cycle. A parent removed by retention makes the child a root.
    static func parentMap(_ tasks: [TaskInfo]) -> [String: String] {
        let ids = Set(tasks.map(\.taskID))
        var parent: [String: String] = [:]
        for task in tasks {
            if let by = task.spawnedBy, by != task.taskID, ids.contains(by) { parent[task.taskID] = by }
        }
        // Break cycles (which a sane record set never has, but disk is not trusted).
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

    /// Build the sidebar. `matches` is the search/backend filter: a tree is kept when any node in
    /// it matches, so a matching sub-task is shown in context.
    public static func sections(_ tasks: [TaskInfo], matches: (TaskInfo) -> Bool = { _ in true }) -> SidebarSections {
        let parent = parentMap(tasks)
        let byID = Dictionary(tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        var childIDs: [String: [String]] = [:]
        for (child, parentID) in parent { childIDs[parentID, default: []].append(child) }

        func node(_ id: String) -> TaskNode {
            let kids = (childIDs[id] ?? []).compactMap { byID[$0] }.sorted(by: startedAscending).map { node($0.taskID) }
            return TaskNode(task: byID[id]!, children: kids)
        }
        func keep(_ node: TaskNode) -> Bool { matches(node.task) || node.children.contains(where: keep) }

        var sections = SidebarSections()
        var groups: [String: [TaskNode]] = [:]
        for task in tasks where parent[task.taskID] == nil {
            let tree = node(task.taskID)
            guard keep(tree) else { continue }
            if let group = task.group {
                groups[group, default: []].append(tree)
            } else if tree.anyRunning {
                sections.running.append(tree)
            } else {
                sections.recent.append(tree)
            }
        }
        // A member whose parent is outside the group (a group started from inside another task)
        // is still a column of that group, and also stays in its parent's tree.
        for task in tasks {
            guard let group = task.group, let parentID = parent[task.taskID], byID[parentID]?.group != group else { continue }
            let tree = node(task.taskID)
            if keep(tree) { groups[group, default: []].append(tree) }
        }
        sections.running.sort { startedDescending($0.task, $1.task) }
        sections.recent.sort { startedDescending($0.task, $1.task) }
        sections.parallel = groups.map { name, members in
            ParallelGroup(name: name, members: members.sorted { startedAscending($0.task, $1.task) })
        }.sorted { ($0.startedAt ?? .distantPast) > ($1.startedAt ?? .distantPast) }
        return sections
    }

    /// Root first, direct parent last — the breadcrumb above a sub-task. A thin wrapper over a
    /// fresh `LineageIndex` (Monitor piece 11) — same behaviour/complexity as before for a single
    /// call; a caller making several of these queries over the same listing builds one
    /// `LineageIndex` instead and reuses it.
    public static func ancestors(of taskID: String, in tasks: [TaskInfo]) -> [TaskInfo] {
        LineageIndex(tasks).ancestors(of: taskID)
    }

    /// A thin wrapper over a fresh `LineageIndex` — see `ancestors(of:in:)`'s doc.
    public static func children(of taskID: String, in tasks: [TaskInfo]) -> [TaskInfo] {
        LineageIndex(tasks).children(of: taskID)
    }

    /// The current parent's other children (F4-38's lineage list) — every child of the nearest
    /// ancestor, current task included, or none for a root task. A thin wrapper over a fresh
    /// `LineageIndex` — see `ancestors(of:in:)`'s doc.
    public static func siblings(of taskID: String, in tasks: [TaskInfo]) -> [TaskInfo] {
        LineageIndex(tasks).siblings(of: taskID)
    }

    public static func members(ofGroup name: String, in tasks: [TaskInfo]) -> [TaskInfo] {
        sections(tasks).parallel.first { $0.name == name }?.members.map(\.task) ?? []
    }

    /// Root tasks seen running in `previous` and settled in `current`: the ones to notify about.
    /// Taken from two listings rather than from `task_finished` alone, so a run whose server died
    /// (and so never wrote that event) still notifies once it is resolved.
    public static func finishedRoots(previous: [TaskInfo], current: [TaskInfo]) -> [TaskInfo] {
        let wasRunning = Set(previous.filter { $0.status.isRunning }.map(\.taskID))
        return current.filter { $0.isRoot && $0.status.isTerminal && wasRunning.contains($0.taskID) }
    }

    /// Left-to-right order for a Parallel group's columns: running members first, then finished
    /// ones, each newest first — so what is still working sits on the left and what is done drifts
    /// to the right.
    public static func parallelColumnOrder(_ members: [TaskInfo]) -> [TaskInfo] {
        members.sorted { lhs, rhs in
            if lhs.status.isRunning != rhs.status.isRunning { return lhs.status.isRunning }
            return startedDescending(lhs, rhs)
        }
    }

    static func startedAscending(_ a: TaskInfo, _ b: TaskInfo) -> Bool {
        let left = a.startedAt ?? .distantPast, right = b.startedAt ?? .distantPast
        return left == right ? a.taskID < b.taskID : left < right
    }

    static func startedDescending(_ a: TaskInfo, _ b: TaskInfo) -> Bool {
        let left = a.startedAt ?? .distantPast, right = b.startedAt ?? .distantPast
        return left == right ? a.taskID < b.taskID : left > right
    }
}
