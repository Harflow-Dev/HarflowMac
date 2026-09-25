import XCTest
@testable import MonitorCore

func task(_ id: String, status: String = "completed", spawnedBy: String? = nil, depth: Int? = nil, group: String? = nil, backend: String = "claude", minute: Int = 0) -> TaskInfo {
    var object: [String: JSONValue] = [
        "task_id": .string(id), "status": .string(status), "backend": .string(backend),
        "depth": .number(Double(depth ?? (spawnedBy == nil ? 0 : 1))),
        "started_at": .string(String(format: "2026-09-25T10:%02d:00+00:00", minute)),
    ]
    if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
    if let group { object["group"] = .string(group) }
    return TaskInfo(.object(object))!
}

final class LineageTests: XCTestCase {
    func testTreesSplitIntoRunningAndRecent() {
        let tasks = [
            task("root", status: "completed", minute: 1),
            task("child", status: "running", spawnedBy: "root", minute: 2),
            task("grandchild", status: "completed", spawnedBy: "child", minute: 3),
            task("done", status: "failed", minute: 4),
            task("new", status: "running", minute: 5),
        ]
        let sections = Lineage.sections(tasks)
        // A settled root with a running descendant is still a running tree.
        XCTAssertEqual(sections.running.map(\.id), ["new", "root"])
        XCTAssertEqual(sections.running[1].children.map(\.id), ["child"])
        XCTAssertEqual(sections.running[1].children[0].children.map(\.id), ["grandchild"])
        XCTAssertEqual(sections.running[1].descendantCount, 2)
        XCTAssertEqual(sections.running[1].flattened().map(\.indent), [0, 1, 2])
        XCTAssertEqual(sections.recent.map(\.id), ["done"])
    }

    func testMissingParentMakesARootAndCyclesAreBroken() {
        let tasks = [
            task("orphan", status: "running", spawnedBy: "gone"),
            task("a", spawnedBy: "b", minute: 1),
            task("b", spawnedBy: "a", minute: 2),
        ]
        let sections = Lineage.sections(tasks)
        XCTAssertEqual(sections.running.map(\.id), ["orphan"])
        let recent = Set(sections.recent.flatMap { $0.flattened().map(\.node.id) })
        XCTAssertEqual(recent, ["a", "b"], "every task still appears exactly somewhere")
        XCTAssertTrue(Lineage.ancestors(of: "a", in: tasks).count <= 1)
    }

    func testGroupsBecomeParallelRunsWithNestedChildrenUnderTheirMember() {
        let tasks = [
            task("r1", status: "completed", group: "plan review", backend: "claude", minute: 1),
            task("r2", status: "running", group: "plan review", backend: "codex", minute: 2),
            task("r2-sub", status: "running", spawnedBy: "r2", group: "plan review", minute: 3),
            task("solo", status: "completed", minute: 4),
        ]
        let sections = Lineage.sections(tasks)
        XCTAssertEqual(sections.parallel.count, 1)
        let group = sections.parallel[0]
        XCTAssertEqual(group.name, "plan review")
        XCTAssertEqual(group.members.map(\.id), ["r1", "r2"], "the inherited label does not make a sub-task a column")
        XCTAssertEqual(group.members[1].children.map(\.id), ["r2-sub"])
        XCTAssertEqual(group.doneCount, 1)
        XCTAssertEqual(group.total, 2)
        XCTAssertTrue(group.anyRunning)
        XCTAssertTrue(sections.running.isEmpty, "grouped tasks are shown once, under Parallel runs")
        XCTAssertEqual(sections.recent.map(\.id), ["solo"])
        XCTAssertEqual(Lineage.members(ofGroup: "plan review", in: tasks).map(\.taskID), ["r1", "r2"])
    }

    func testGroupStartedFromInsideATaskIsStillAParallelRun() {
        let tasks = [
            task("lead", status: "running", minute: 0),
            task("g1", status: "running", spawnedBy: "lead", group: "fanout", minute: 1),
            task("g2", status: "completed", spawnedBy: "lead", group: "fanout", minute: 2),
        ]
        let sections = Lineage.sections(tasks)
        XCTAssertEqual(sections.parallel.first?.members.map(\.id), ["g1", "g2"])
        XCTAssertEqual(sections.running.first?.children.map(\.id), ["g1", "g2"])
    }

    func testFilterKeepsATreeWhenAnyNodeMatches() {
        let tasks = [
            task("root", status: "running", backend: "claude"),
            task("kid", status: "running", spawnedBy: "root", backend: "codex"),
            task("other", status: "completed", backend: "claude"),
        ]
        let sections = Lineage.sections(tasks) { $0.backend == "codex" }
        XCTAssertEqual(sections.running.map(\.id), ["root"])
        XCTAssertTrue(sections.recent.isEmpty)
    }

    func testAncestorsAndChildren() {
        let tasks = [task("r"), task("p", spawnedBy: "r", minute: 1), task("c", spawnedBy: "p", depth: 2, minute: 2), task("sib", spawnedBy: "p", depth: 2, minute: 3)]
        XCTAssertEqual(Lineage.ancestors(of: "c", in: tasks).map(\.taskID), ["r", "p"])
        XCTAssertEqual(Lineage.children(of: "p", in: tasks).map(\.taskID), ["c", "sib"])
        XCTAssertTrue(Lineage.ancestors(of: "r", in: tasks).isEmpty)
    }

    func testFinishedRootsAreOnlyRootsSeenRunningBefore() {
        let before = [task("a", status: "running"), task("b", status: "running", spawnedBy: "a"), task("c", status: "running"), task("d", status: "completed")]
        let after = [task("a", status: "completed"), task("b", status: "completed", spawnedBy: "a"), task("c", status: "running"), task("d", status: "completed"), task("e", status: "failed")]
        XCTAssertEqual(Lineage.finishedRoots(previous: before, current: after).map(\.taskID), ["a"])
        XCTAssertTrue(Lineage.finishedRoots(previous: [], current: after).isEmpty, "a first listing notifies nothing")
    }
}
