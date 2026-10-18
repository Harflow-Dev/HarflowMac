import Foundation
@testable import MonitorCore
import Testing

/// Monitor piece 11: `ConversationIndex` replaced `Lineage.conversationSections(_:matches:)`/
/// `conversationAncestors(of:in:)`/`conversationChildren(of:in:)`/`conversationID(of:in:)`/
/// `conversation(containing:in:)` each rebuilding the whole conversation tree from scratch on every
/// call — measured at 0.36s/recompute for `SidebarVM`'s per-matching-task `forcedExpandedIDs` loop
/// on a 532-task real listing with a backend tab selected (113 matches), O(n²) over the number of
/// matching tasks. `ConversationTests.swift`'s existing suite already pins the exact behaviour those
/// five entry points must keep (unchanged by this refactor) — this file adds two things Plan review
/// round 1, item 5 asks for on top of that: an INDEPENDENT oracle (a differently-structured
/// computation, never sharing `ConversationIndex`'s own parent/children maps) to catch a refactor
/// mistake those pinned tests would not — and the perf bound that proves the fix.
@Suite
struct ConversationIndexTests {

    // MARK: - Independent oracle

    /// A deliberately DIFFERENT computation from `ConversationIndex`'s shared parent/children maps:
    /// walks one step at a time via `Lineage.conversation(containing:)`/`conversations(_:)` (both
    /// untouched by this refactor) rather than a precomputed map, so an equivalence failure here
    /// means the refactor actually changed behaviour, not that the oracle shares its bug.
    private enum IndependentOracle {
        static func ancestors(of taskID: String, in tasks: [TaskInfo]) -> [Conversation] {
            guard var current = Lineage.conversation(containing: taskID, in: tasks) else { return [] }
            var chain: [Conversation] = []
            var seen: Set<String> = [current.id]
            while let spawner = current.first.spawnedBy,
                  let spawnerConv = Lineage.conversation(containing: spawner, in: tasks),
                  spawnerConv.id != current.id, !seen.contains(spawnerConv.id) {
                chain.insert(spawnerConv, at: 0)
                seen.insert(spawnerConv.id)
                current = spawnerConv
            }
            return chain
        }

        static func children(of conversationID: String, in tasks: [TaskInfo]) -> [Conversation] {
            Lineage.conversations(tasks).filter { conv in
                guard let spawner = conv.first.spawnedBy,
                      let spawnerConv = Lineage.conversation(containing: spawner, in: tasks) else { return false }
                return spawnerConv.id == conversationID && spawnerConv.id != conv.id
            }
        }

        static func sections(_ tasks: [TaskInfo], matches: (TaskInfo) -> Bool = { _ in true }) -> ConversationSections {
            func node(_ conv: Conversation) -> ConversationNode {
                let kids = children(of: conv.id, in: tasks)
                    .sorted { Lineage.startedAscending($0.first, $1.first) }
                    .map(node)
                return ConversationNode(conversation: conv, children: kids)
            }
            func keep(_ node: ConversationNode) -> Bool {
                node.conversation.members.contains(where: matches) || node.children.contains(where: keep)
            }
            var sections = ConversationSections()
            for conv in Lineage.conversations(tasks) where ancestors(of: conv.id, in: tasks).isEmpty && conv.first.group == nil {
                let tree = node(conv)
                guard keep(tree) else { continue }
                if tree.anyRunning { sections.running.append(tree) } else { sections.recent.append(tree) }
            }
            sections.running.sort { Lineage.startedDescending($0.conversation.current, $1.conversation.current) }
            sections.recent.sort { Lineage.startedDescending($0.conversation.current, $1.conversation.current) }
            return sections
        }
    }

    /// Flattens both sides to a comparable shape (conversation ids in tree order, per section) so
    /// one `#expect` catches a mismatch anywhere in the tree, root order included.
    private func flatShape(_ sections: ConversationSections) -> (running: [[String]], recent: [[String]]) {
        (
            running: sections.running.map { $0.flattened().map(\.node.id) },
            recent: sections.recent.map { $0.flattened().map(\.node.id) }
        )
    }

    @Test
    func givenAChainOfResumes_whenComparedToTheIndependentOracle_thenAncestorsAndChildrenMatch() {
        // given
        let tasks = [
            task("root"), task("mid", spawnedBy: "root", minute: 1),
            task("mid-b", parentTaskID: "mid", minute: 2), task("leaf", spawnedBy: "mid-b", minute: 3)
        ]
        // when / then
        let index = ConversationIndex(tasks)
        #expect(index.ancestors(ofConversationContaining: "leaf").map(\.id) == IndependentOracle.ancestors(of: "leaf", in: tasks).map(\.id))
        #expect(index.children(of: "mid").map(\.id) == IndependentOracle.children(of: "mid", in: tasks).map(\.id))
        #expect(flatShape(index.sections()) == flatShape(IndependentOracle.sections(tasks)))
    }

    @Test
    func givenBranchingResumesAndAGroupedRoot_whenComparedToTheIndependentOracle_thenSectionsMatch() {
        // given — a branching resume chain (A -> B, A -> C) alongside a grouped root (excluded from
        // Running/Recent entirely) and a solo chain, mirroring `ConversationTests`'s own fixtures.
        let tasks = [
            task("a"), task("b", parentTaskID: "a", minute: 1), task("c", status: "running", parentTaskID: "a", minute: 2),
            task("r1", status: "completed", group: "plan review", minute: 3), task("r2", status: "completed", group: "plan review", minute: 4),
            task("solo-a", minute: 5), task("solo-b", parentTaskID: "solo-a", minute: 6)
        ]
        // when / then
        let index = ConversationIndex(tasks)
        #expect(flatShape(index.sections()) == flatShape(IndependentOracle.sections(tasks)))
        #expect(index.conversationID(of: "b") == "a")
        #expect(index.conversationID(of: "unknown") == "unknown", "an id absent from the listing normalises to itself")
    }

    @Test
    func givenATaskWhoseParentIsMissing_whenComparedToTheIndependentOracle_thenItStartsItsOwnConversationInBoth() {
        // given — retention removed "a", or it never existed on disk.
        let tasks = [task("b", parentTaskID: "a")]
        // when / then
        let index = ConversationIndex(tasks)
        #expect(flatShape(index.sections()) == flatShape(IndependentOracle.sections(tasks)))
        #expect(index.conversation(containing: "b")?.members.map(\.taskID) == ["b"])
    }

    @Test
    func givenAWholeTreeFilteredOutByASearch_whenComparedToTheIndependentOracle_thenRetentionRecordsTheUnfilteredWholeTree() {
        // given — Codex review round 2, finding 3's exact scenario: a filter hides an entire
        // conversation from `sections(matches:)`, but the UNFILTERED `sections()` must still see it
        // whole (SidebarVM's own `recordMembership` reads exactly this unfiltered call).
        let tasks = [task("a", backend: "codex"), task("b", parentTaskID: "a", backend: "codex", minute: 1)]
        let matchesClaude: (TaskInfo) -> Bool = { $0.backend == "claude" }
        // when
        let index = ConversationIndex(tasks)
        let filtered = index.sections(matches: matchesClaude)
        let unfiltered = index.sections()
        // then
        #expect(filtered.running.isEmpty && filtered.recent.isEmpty, "the whole conversation is hidden by the filter")
        #expect(flatShape(unfiltered) == flatShape(IndependentOracle.sections(tasks)))
        #expect(unfiltered.recent.map(\.id) == ["a"])
    }

    @Test
    func givenACycleInParentTaskID_whenIndexed_thenEveryTaskStillAppearsExactlyOnce() {
        // given — corrupted data: a <-> b via parent_task_id. Cycle-break is order-dependent (Plan
        // review round 1, item 5), so this asserts only the invariant every representation must
        // hold, not one particular shape.
        let tasks = [task("a", parentTaskID: "b"), task("b", parentTaskID: "a", minute: 1)]
        // when
        let sections = ConversationIndex(tasks).sections()
        // then
        let allMembers = (sections.running + sections.recent).flatMap { $0.flattened().flatMap { $0.node.conversation.members.map(\.taskID) } }
        #expect(Set(allMembers) == ["a", "b"])
        #expect(allMembers.count == 2, "no task is placed twice, and none is dropped")
    }

    // MARK: - Perf (Monitor piece 11)

    @Test
    func givenA2000TaskListingWithABackendFilterActive_whenRunningTheSidebarsPerTaskAncestorLoop_thenItStaysWellUnderASecond() {
        // given — the exact shape that cost 0.36s/recompute on the real 532-task listing:
        // `SidebarVM.recompute()`'s `forcedExpandedIDs` calls `ancestors(ofConversationContaining:)`
        // once per MATCHING task. Built once and reused here (Plan review round 1, item 1) instead of
        // each call rebuilding the whole tree — the fix under test.
        let tasks = (0 ..< 2000).map { index in
            task(
                "t\(index)", status: index % 7 == 0 ? "running" : "completed",
                spawnedBy: index % 5 == 0 && index > 0 ? "t\(index - 1)" : nil,
                parentTaskID: index % 3 == 0 && index > 0 ? "t\(index - 1)" : nil, backend: index % 2 == 0 ? "claude" : "codex",
                minute: index % 60
            )
        }
        let matches: (TaskInfo) -> Bool = { $0.backend == "claude" }
        let start = Date()
        // when
        let index = ConversationIndex(tasks)
        let sections = index.sections(matches: matches)
        let forcedExpandedIDs = Set(tasks.filter(matches).flatMap { index.ancestors(ofConversationContaining: $0.taskID).map(\.id) })
        // then
        let elapsed = Date().timeIntervalSince(start)
        #expect(!sections.recent.isEmpty || !sections.running.isEmpty)
        #expect(!forcedExpandedIDs.isEmpty, "the fixture actually exercises ancestor expansion, so this isn't measuring an empty loop")
        #expect(elapsed < 0.5, "one shared index reused per matching task should stay well under a second even at 2x the real listing's size (\(elapsed)s)")
    }
}
