import Foundation
@testable import MonitorCore
import Testing

@Suite
struct LineageTests {
    @Test
    func givenARunningTreeAndAFinishedTask_whenSectioned_thenTheyLandInRunningAndRecent() {
        // given
        let tasks = [
            task("root", status: "completed", minute: 1),
            task("child", status: "running", spawnedBy: "root", minute: 2),
            task("grandchild", status: "completed", spawnedBy: "child", minute: 3),
            task("done", status: "failed", minute: 4),
            task("new", status: "running", minute: 5)
        ]
        // when
        let sections = Lineage.sections(tasks)
        // then
        // A settled root with a running descendant is still a running tree.
        #expect(sections.running.map(\.id) == ["new", "root"])
        #expect(sections.running[1].children.map(\.id) == ["child"])
        #expect(sections.running[1].children[0].children.map(\.id) == ["grandchild"])
        #expect(sections.running[1].descendantCount == 2)
        #expect(sections.running[1].flattened().map(\.indent) == [0, 1, 2])
        #expect(sections.recent.map(\.id) == ["done"])
    }

    @Test
    func givenAMissingParentAndACycle_whenSectioned_thenAnOrphanBecomesARootAndTheCycleBreaks() {
        // given
        let tasks = [
            task("orphan", status: "running", spawnedBy: "gone"),
            task("a", spawnedBy: "b", minute: 1),
            task("b", spawnedBy: "a", minute: 2)
        ]
        // when
        let sections = Lineage.sections(tasks)
        // then
        #expect(sections.running.map(\.id) == ["orphan"])
        let recent = Set(sections.recent.flatMap { $0.flattened().map(\.node.id) })
        #expect(recent == ["a", "b"], "every task still appears exactly somewhere")
        #expect(Lineage.ancestors(of: "a", in: tasks).count <= 1)
    }

    @Test
    func givenGroupedTasksWithASubTask_whenSectioned_thenTheyBecomeAParallelRunWithNestedChildren() {
        // given
        let tasks = [
            task("r1", status: "completed", group: "plan review", backend: "claude", minute: 1),
            task("r2", status: "running", group: "plan review", backend: "codex", minute: 2),
            task("r2-sub", status: "running", spawnedBy: "r2", group: "plan review", minute: 3),
            task("solo", status: "completed", minute: 4)
        ]
        // when
        let sections = Lineage.sections(tasks)
        // then
        #expect(sections.parallel.count == 1)
        let group = sections.parallel[0]
        #expect(group.name == "plan review")
        #expect(group.members.map(\.id) == ["r1", "r2"], "the inherited label does not make a sub-task a column")
        #expect(group.members[1].children.map(\.id) == ["r2-sub"])
        #expect(group.doneCount == 1)
        #expect(group.total == 2)
        #expect(group.anyRunning)
        #expect(sections.running.isEmpty, "grouped tasks are shown once, under Parallel runs")
        #expect(sections.recent.map(\.id) == ["solo"])
        #expect(Lineage.members(ofGroup: "plan review", in: tasks).map(\.taskID) == ["r1", "r2"])
    }

    @Test
    func givenAGroupStartedFromInsideARunningTask_whenSectioned_thenItIsStillAParallelRun() {
        // given
        let tasks = [
            task("lead", status: "running", minute: 0),
            task("g1", status: "running", spawnedBy: "lead", group: "fanout", minute: 1),
            task("g2", status: "completed", spawnedBy: "lead", group: "fanout", minute: 2)
        ]
        // when
        let sections = Lineage.sections(tasks)
        // then
        #expect(sections.parallel.first?.members.map(\.id) == ["g1", "g2"])
        #expect(sections.running.first?.children.map(\.id) == ["g1", "g2"])
    }

    @Test
    func givenABackendFilter_whenSectioned_thenAWholeTreeIsKeptWhenAnyNodeMatches() {
        // given
        let tasks = [
            task("root", status: "running", backend: "claude"),
            task("kid", status: "running", spawnedBy: "root", backend: "codex"),
            task("other", status: "completed", backend: "claude")
        ]
        // when
        let sections = Lineage.sections(tasks) { $0.backend == "codex" }
        // then
        #expect(sections.running.map(\.id) == ["root"])
        #expect(sections.recent.isEmpty)
    }

    @Test
    func givenATaskTree_whenAskedForAncestorsAndChildren_thenTheyMatchTheSpawnedByChain() {
        // given
        let tasks = [
            task("r"), task("p", spawnedBy: "r", minute: 1), task("c", spawnedBy: "p", depth: 2, minute: 2),
            task("sib", spawnedBy: "p", depth: 2, minute: 3)
        ]
        // when / then
        #expect(Lineage.ancestors(of: "c", in: tasks).map(\.taskID) == ["r", "p"])
        #expect(Lineage.children(of: "p", in: tasks).map(\.taskID) == ["c", "sib"])
        #expect(Lineage.ancestors(of: "r", in: tasks).isEmpty)
    }

    @Test
    func givenRootsSeenRunningBefore_whenComparedToTheCurrentListing_thenOnlyThoseNowFinishedAreReported() {
        // given
        let before = [task("a", status: "running"), task("b", status: "running", spawnedBy: "a"), task("c", status: "running"), task("d", status: "completed")]
        let after = [
            task("a", status: "completed"), task("b", status: "completed", spawnedBy: "a"), task("c", status: "running"),
            task("d", status: "completed"), task("e", status: "failed")
        ]
        // when / then
        #expect(Lineage.finishedRoots(previous: before, current: after).map(\.taskID) == ["a"])
        #expect(Lineage.finishedRoots(previous: [], current: after).isEmpty, "a first listing notifies nothing")
    }
}
