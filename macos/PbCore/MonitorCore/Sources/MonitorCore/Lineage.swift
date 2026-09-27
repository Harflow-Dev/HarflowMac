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

    /// Root first, direct parent last — the breadcrumb above a sub-task.
    public static func ancestors(of taskID: String, in tasks: [TaskInfo]) -> [TaskInfo] {
        let parent = parentMap(tasks)
        let byID = Dictionary(tasks.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
        var chain: [TaskInfo] = []
        var cursor = parent[taskID]
        while let id = cursor, let task = byID[id] {
            chain.insert(task, at: 0)
            cursor = parent[id]
        }
        return chain
    }

    public static func children(of taskID: String, in tasks: [TaskInfo]) -> [TaskInfo] {
        let parent = parentMap(tasks)
        return tasks.filter { parent[$0.taskID] == taskID }.sorted(by: startedAscending)
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
